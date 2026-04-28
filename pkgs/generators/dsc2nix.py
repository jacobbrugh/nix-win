#!/usr/bin/env python3
"""Generate a typed nix-win Nix module from a DSC v3 resource manifest, JSON schema, or MOF file.

Usage:
  dsc2nix.py <manifest.dsc.resource.json>
  dsc2nix.py --schema-json <schema.json> --resource-type <Type> [--resource-description <desc>]
  dsc2nix.py --mof <resource.schema.mof> --resource-type <Type> [--resource-description <desc>]

Modes (--mode):
  native        (default) attrsOf, one attrset item = one DSC resource
  psdsc-wrapper attrsOf, one item = one Microsoft.Windows/WindowsPowerShell wrapping an inner type
  container     attrsOf mapped to ONE DSC resource with all items as an array property

Additional flags:
  --wrapper-adapter TYPE   Adapter for psdsc-wrapper (default: Microsoft.Windows/WindowsPowerShell)
  --wrapper-inner-type T   Inner resource type for psdsc-wrapper mode
  --array-prop PROP        Array property name for container mode (default: rules)
  --container-name STR     DSC resource name for container mode (default: "<Type> Config")
  --option-path PATH       Nix option path, dot-separated (default: win.dsc.resource."<Type>")
  --schema-json            Input is a plain JSON schema file, not a manifest
  --mof                    Input is a MOF schema file (.schema.mof); requires --resource-type
  --resource-type TYPE     Resource type (required with --schema-json / --mof)
  --resource-description S Description (optional with --schema-json / --mof)
"""

import argparse
import json
import re
import sys
from pathlib import Path


def escape_nix(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def indent(text: str, n: int) -> str:
    pad = " " * n
    return "\n".join(pad + line if line.strip() else line for line in text.splitlines())


def map_nix_type(prop: dict, required: bool, definitions: dict | None = None, depth: int = 0) -> str:
    """Return a Nix type expression string for a JSON schema property."""
    # Handle nullable types like ["string", "null"] or ["object", "null"]
    actual_type = prop.get("type")
    if isinstance(actual_type, list):
        non_null = [t for t in actual_type if t != "null"]
        actual_type = non_null[0] if non_null else "string"

    if "enum" in prop:
        values = " ".join(f'"{v}"' for v in prop["enum"])
        base = f"(lib.types.enum [ {values} ])"
    elif actual_type == "array":
        items = prop.get("items", {})
        if "enum" in items:
            vals = " ".join(f'"{v}"' for v in items["enum"])
            item_nix = f"(lib.types.enum [ {vals} ])"
        else:
            item_nix = {
                "string": "lib.types.str",
                "integer": "lib.types.int",
                "boolean": "lib.types.bool",
                "number": "(lib.types.either lib.types.int lib.types.float)",
            }.get(items.get("type", "string"), "lib.types.str")
        base = f"(lib.types.listOf {item_nix})"
    elif actual_type == "boolean":
        base = "lib.types.bool"
    elif actual_type == "integer":
        base = "lib.types.int"
    elif actual_type == "number":
        base = "(lib.types.either lib.types.int lib.types.float)"
    elif actual_type == "object" and "properties" in prop and depth < 2:
        # Inline submodule for nested objects
        sub = generate_options(prop["properties"], prop.get("required", []), definitions, depth + 1)
        # Dedent sub back to 0, then re-indent cleanly inside the submodule block
        sub_stripped = "\n".join(line.lstrip() for line in sub.splitlines())
        sub_indented = "\n".join("          " + line if line.strip() else line for line in sub_stripped.splitlines())
        base = f"(lib.types.submodule {{\n          options = {{\n{sub_indented}\n          }};\n        }})"
    else:
        base = "lib.types.str"

    if required:
        return base
    else:
        return f"(lib.types.nullOr {base})"


def generate_options(properties: dict, required_list: list, definitions: dict | None, depth: int = 0, skip_props: set | None = None) -> str:
    required_set = set(required_list)
    skip_props = skip_props or set()
    # Skip readOnly properties and key props (auto-set from attrset key)
    settable = {k: v for k, v in properties.items() if not v.get("readOnly", False) and k not in skip_props}

    lines = []
    for prop_name, prop in settable.items():
        required = prop_name in required_set
        nix_type = map_nix_type(prop, required, definitions, depth)
        desc = escape_nix(prop.get("description", prop.get("title", "")))
        lines.append(f'        {prop_name} = lib.mkOption {{')
        lines.append(f'          type = {nix_type};')
        if not required:
            lines.append('          default = null;')
        lines.append(f'          description = "{desc}";')
        lines.append('        };')
    return "\n".join(lines)


def is_submodule_prop(prop: dict) -> bool:
    """Return True if the property maps to a Nix submodule (nested object)."""
    actual_type = prop.get("type")
    if isinstance(actual_type, list):
        actual_type = next((t for t in actual_type if t != "null"), None)
    return actual_type == "object" and "properties" in prop


def generate_inherit_list(properties: dict, skip_props: set | None = None) -> str:
    skip_props = skip_props or set()
    settable = [k for k, v in properties.items()
                if not v.get("readOnly", False) and k not in skip_props and not is_submodule_prop(v)]
    return "\n          ".join(settable)


def generate_submodule_assignments(properties: dict, skip_props: set | None = None) -> str:
    """Generate Nix assignments for submodule properties that strip inner nulls."""
    skip_props = skip_props or set()
    submodules = [k for k, v in properties.items()
                  if not v.get("readOnly", False) and k not in skip_props and is_submodule_prop(v)]
    lines = []
    for name in submodules:
        lines.append(
            f"{name} =\n"
            f"              if props.{name} != null\n"
            f"              then lib.filterAttrs (_: v: v != null) props.{name}\n"
            f"              else null;"
        )
    return "\n            ".join(lines)


def instance_field_to_nix(prop: dict, required: bool) -> tuple[str, str | None, str | None]:
    """Map a DSC v3 instance-record framework field to a Nix option.

    Returns (type_expr, default, sentinel). `default` and `sentinel` are None
    for required fields (the option then has no default and is always emitted
    in the resource record). For optional fields, `sentinel` is the value the
    emit block compares against to decide whether to include the field.
    """
    actual_type = prop.get("type")
    if isinstance(actual_type, list):
        actual_type = next((t for t in actual_type if t != "null"), None)

    if actual_type == "array":
        items = prop.get("items", {})
        item_nix = {
            "string": "lib.types.str",
            "integer": "lib.types.int",
            "boolean": "lib.types.bool",
            "number": "(lib.types.either lib.types.int lib.types.float)",
        }.get(items.get("type", "string"), "lib.types.str")
        if required:
            return f"(lib.types.listOf {item_nix})", None, None
        return f"(lib.types.listOf {item_nix})", "[ ]", "[ ]"
    if actual_type == "boolean":
        base = "lib.types.bool"
    elif actual_type == "integer":
        base = "lib.types.int"
    elif actual_type == "number":
        base = "(lib.types.either lib.types.int lib.types.float)"
    elif actual_type == "object":
        base = "lib.types.attrs"
    else:  # string, datetime, anything unknown
        base = "lib.types.str"
    if required:
        return base, None, None
    return f"(lib.types.nullOr {base})", "null", "null"


# Resource-instance fields the generator already handles itself — these are
# never surfaced as Nix options on consumer modules:
#   - `name`     : set from the Nix attrset key (or container_name in container mode)
#   - `type`     : set from --resource-type / --wrapper-adapter
#   - `properties`: populated from the per-resource type schema (MOF/JSON)
INSTANCE_FIELDS_HANDLED_BY_GENERATOR = {"name", "type", "properties"}


def parse_instance_schema(content: str) -> list[dict]:
    """Parse a DSC v3 `document.resource.json` schema and return the list of
    author-settable framework fields (those that should appear as Nix options
    on every generated module and be threaded into the emitted resource record).

    Skips fields the generator handles itself — see
    INSTANCE_FIELDS_HANDLED_BY_GENERATOR.
    """
    schema = json.loads(content)
    required_set = set(schema.get("required", []))
    out: list[dict] = []
    for fname, fschema in schema.get("properties", {}).items():
        if fname in INSTANCE_FIELDS_HANDLED_BY_GENERATOR:
            continue
        is_required = fname in required_set
        type_expr, default, sentinel = instance_field_to_nix(fschema, is_required)
        desc = fschema.get("description") or fschema.get("title") or ""
        desc = re.sub(r"\s+", " ", desc).strip()
        if len(desc) > 400:
            desc = desc[:397] + "..."
        out.append({
            "name": fname,
            "type_expr": type_expr,
            "default": default,
            "sentinel": sentinel,
            "description": desc,
        })
    return out


def render_framework_options(fields: list[dict], leading_indent: str) -> str:
    """Render Nix option declarations for framework instance fields, joined to
    sit inside the per-resource submodule's `options = { ... }` block."""
    if not fields:
        return ""
    lines: list[str] = []
    for f in fields:
        lines.append(f'{leading_indent}{f["name"]} = lib.mkOption {{')
        lines.append(f'{leading_indent}  type = {f["type_expr"]};')
        if f["default"] is not None:
            lines.append(f'{leading_indent}  default = {f["default"]};')
        lines.append(f'{leading_indent}  description = "{escape_nix(f["description"])}";')
        lines.append(f'{leading_indent}}};')
    return "\n".join(lines)


def render_framework_threads(fields: list[dict], indent: str) -> str:
    """Render the `// (lib.optionalAttrs ...)` lines that thread framework
    fields onto the emitted resource record. One line per field."""
    if not fields:
        return ""
    lines: list[str] = []
    for f in fields:
        if f["sentinel"] is None:
            # Required: always emit. (No DSC v3 instance field is currently
            # required besides `name` and `type` which the generator handles
            # itself, but keep the branch for forward compatibility.)
            lines.append(f'{indent}// {{ inherit (props) {f["name"]}; }}')
        else:
            lines.append(
                f'{indent}// (lib.optionalAttrs (props.{f["name"]} != {f["sentinel"]}) '
                f'{{ inherit (props) {f["name"]}; }})'
            )
    return "\n".join(lines)


def parse_mof_schema(content: str) -> dict:
    """Parse a DSC .schema.mof file and return a JSON schema dict.

    Finds the OMI_BaseResource (or MSFT_BaseResourceConfiguration) subclass,
    extracts all properties with their types, Key/Write/Read qualifiers,
    ValueMap/Values enums, and EmbeddedInstance types.
    """
    # Match classes extending any known DSC base class (qualifier block is optional)
    class_m = re.search(
        r'(?:\[[^\]]*\]\s*\n?)?\bclass\s+\w+\s*:\s*(?:OMI_BaseResource|MSFT_BaseResourceConfiguration)\b\s*\{(.*?)\};',
        content, re.DOTALL | re.IGNORECASE,
    )
    if not class_m:
        raise ValueError("No OMI_BaseResource subclass found in MOF content")

    class_body = class_m.group(1)
    properties: dict = {}
    required_list: list[str] = []

    # Each property: [qualifiers] MofType PropName[] ;
    prop_re = re.compile(r'\[([^\]]+)\]\s+(\w+)\s+(\w+)(\[\])?\s*;', re.DOTALL)

    for m in prop_re.finditer(class_body):
        qual_str = m.group(1)
        mof_type = m.group(2).lower()
        name = m.group(3)
        is_array = m.group(4) is not None

        # Strip quoted string content before checking qualifiers so that
        # words like "key" in Description text don't trigger false positives.
        qual_names = re.sub(r'"[^"]*"', '""', qual_str)
        is_key = bool(re.search(r'\bKey\b', qual_names, re.IGNORECASE))
        is_read = bool(re.search(r'\bRead\b', qual_names, re.IGNORECASE))

        desc_m = re.search(r'Description\("(.*?)"\)', qual_str, re.DOTALL)
        desc = re.sub(r'\s+', ' ', desc_m.group(1)).strip() if desc_m else ""
        if len(desc) > 400:
            desc = desc[:397] + "..."

        # Support both ValueMap{"..."} and Values{"..."} (OMI uses Values)
        vm_m = re.search(r'(?:ValueMap|Values)\s*\{([^}]+)\}', qual_str)
        enum_vals: list[str] | None = None
        if vm_m:
            enum_vals = [v.strip().strip('"') for v in vm_m.group(1).split(',')]

        ei_m = re.search(r'EmbeddedInstance\("(\w+)"\)', qual_str)
        embedded = ei_m.group(1) if ei_m else None

        # Map MOF type → JSON schema base
        if embedded == "MSFT_Credential":
            item: dict = {
                "type": "object",
                "properties": {
                    "UserName": {"type": "string", "description": "The username to run the task as."},
                    "Password": {"type": "string", "description": "The password for the user account."},
                },
            }
        elif embedded:
            item = {"type": "object"}
        elif mof_type == "boolean":
            item = {"type": "boolean"}
        elif mof_type in ("uint8", "uint16", "uint32", "uint64", "sint8", "sint16", "sint32", "sint64"):
            item = {"type": "integer"}
        elif mof_type in ("real32", "real64"):
            item = {"type": "number"}
        else:  # string, datetime, char16, …
            item = {"type": "string"}

        if enum_vals and "enum" not in item:
            item["enum"] = enum_vals

        if is_array:
            prop_schema: dict = {
                "type": "array",
                "description": desc,
                "items": {k: v for k, v in item.items()},
            }
        else:
            prop_schema = {**item, "description": desc}

        # Read-only properties are marked as such (generator will skip them)
        if is_read:
            prop_schema["readOnly"] = True

        # Non-key properties are nullable
        if not is_key:
            t = prop_schema.get("type")
            if isinstance(t, str):
                prop_schema["type"] = [t, "null"]
        else:
            required_list.append(name)

        properties[name] = prop_schema

    return {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "required": required_list,
        "properties": properties,
    }


def load_schema(args) -> tuple[str, str, dict]:
    """Returns (resource_type, resource_description, schema)."""
    if getattr(args, 'mof', False):
        content = Path(args.source).read_text()
        resource_type = args.resource_type
        if not resource_type:
            raise ValueError("--resource-type is required with --mof")
        resource_description = args.resource_description or ""
        schema = parse_mof_schema(content)
        return resource_type, resource_description, schema
    elif args.schema_json:
        with open(args.source) as f:
            data = json.load(f)
        resource_type = args.resource_type or data.get("type", "Unknown/Resource")
        resource_description = args.resource_description or data.get("description", "")
        schema = data.get("schema", data)
        return resource_type, resource_description, schema
    else:
        with open(args.source) as f:
            manifest = json.load(f)
        resource_type = args.resource_type or manifest["type"]
        resource_description = args.resource_description or manifest.get("description", "")
        embedded = manifest.get("schema", {}).get("embedded")
        if not embedded:
            raise ValueError(
                f"Resource {resource_type} has no schema.embedded. "
                "Provide a pre-extracted schema JSON with --schema-json."
            )
        return resource_type, resource_description, embedded


def option_path_to_nix(path: str) -> str:
    """Convert dot-separated option path to Nix attr accessor."""
    # e.g. win.dsc.firewall.rules -> win.dsc.firewall.rules
    # e.g. 'win.dsc.resource."Microsoft.Windows/Service"' -> as-is
    return path


def option_path_to_attr(path: str) -> str:
    """Convert dot-separated path to Nix cfg.xxx.yyy attribute access."""
    return "cfg." + ".".join(
        f'"{p}"' if ("/" in p or "." in p) else p
        for p in path.split(".")
    )


def generate_module(args) -> str:
    resource_type, resource_description, schema = load_schema(args)

    mode = args.mode
    properties = schema.get("properties", {})
    required_list = schema.get("required", [])

    # For container mode: item schema is inside the array property
    if mode == "container":
        array_prop = args.array_prop or "rules"
        if array_prop in properties:
            item_schema = properties[array_prop].get("items", {})
            item_properties = item_schema.get("properties", {})
            item_required = item_schema.get("required", [])
        else:
            raise ValueError(f"Array property '{array_prop}' not found in schema")
        work_properties = item_properties
        work_required = item_required
    else:
        work_properties = properties
        work_required = required_list

    # Option path
    if args.option_path:
        nix_option_path = args.option_path
    elif mode == "psdsc-wrapper":
        inner = args.wrapper_inner_type or resource_type
        nix_option_path = f'win.dsc.resource."{inner}"'
    else:
        nix_option_path = f'win.dsc.resource."{resource_type}"'

    # Build the option path for use in config section
    # Split off "win.dsc" prefix → cfg_attr
    if nix_option_path.startswith("win.dsc."):
        cfg_suffix = nix_option_path[len("win.dsc."):]
        # Handle quoted segments
        cfg_attr = "cfg." + cfg_suffix
    else:
        cfg_attr = "config." + nix_option_path

    key_prop = args.key_prop or None
    skip_props = {key_prop} if key_prop else set()
    options_str = generate_options(work_properties, work_required, None, skip_props=skip_props)
    inherit_str = generate_inherit_list(work_properties, skip_props=skip_props)
    submodule_str = generate_submodule_assignments(work_properties, skip_props=skip_props)

    # Framework-level instance fields: parsed from the DSC v3
    # `document.resource.json` schema and surfaced as Nix options on every
    # generated module (native + psdsc-wrapper). Container mode emits a
    # single aggregated resource; framework fields would be ambiguous at
    # the per-item level and are not supported there.
    framework_fields: list[dict] = []
    if mode in ("native", "psdsc-wrapper"):
        if not args.instance_schema:
            raise ValueError(
                f"--instance-schema is required for mode={mode}; without it, "
                "the generator can't surface DSC v3 framework-level fields "
                "(dependsOn, etc.) on the emitted resource record."
            )
        framework_fields = parse_instance_schema(Path(args.instance_schema).read_text())

    framework_options_str = render_framework_options(framework_fields, "        ")
    if framework_options_str:
        options_str = options_str + "\n" + framework_options_str if options_str else framework_options_str

    source_note = Path(args.source).name
    regen_cmd = "nix build .#packages.x86_64-linux.generate-dsc-modules"

    # Build the properties block contents: inherit for flat props, explicit for submodules
    def _props_block(extra_indent: str = "") -> str:
        parts = []
        if inherit_str:
            parts.append(f"inherit (props)\n{extra_indent}          {inherit_str}\n{extra_indent}          ;")
        if submodule_str:
            parts.append(submodule_str)
        return f"\n{extra_indent}        ".join(parts)

    if mode == "native":
        props = _props_block()
        threads = render_framework_threads(framework_fields, "      ")
        threads_block = f"\n{threads}" if threads else ""
        config_block = f'''\
  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (
      rname: props:
      {{
        name = rname;
        type = "{resource_type}";
        properties = lib.filterAttrs (_: v: v != null) {{
          {props}
        }};
      }}{threads_block}
    ) {cfg_attr}
  );'''

    elif mode == "psdsc-wrapper":
        adapter = args.wrapper_adapter or "Microsoft.Windows/WindowsPowerShell"
        inner_type = args.wrapper_inner_type or resource_type
        key_inject = f'\n            {key_prop} = rname;' if key_prop else ""
        props = _props_block("    ")
        threads = render_framework_threads(framework_fields, "      ")
        threads_block = f"\n{threads}" if threads else ""
        config_block = f'''\
  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (
      rname: props:
      {{
        name = rname;
        type = "{adapter}";
        properties.resources = [
          {{
            name = "${{rname}} Inner";
            type = "{inner_type}";
            properties = lib.filterAttrs (_: v: v != null) {{{key_inject}
              {props}
            }};
          }}
        ];
      }}{threads_block}
    ) {cfg_attr}
  );'''

    elif mode == "container":
        # Framework fields not surfaced in container mode — see the
        # `framework_fields` initialization above.
        container_name = args.container_name or f"{resource_type} Config"
        config_block = f'''\
  config.win.dsc.nativeResourcesList = lib.mkIf (cfg.enable && {cfg_attr} != {{ }}) [
    {{
      name = "{container_name}";
      type = "{resource_type}";
      properties.{array_prop} = lib.mapAttrsToList (rname: props:
        lib.filterAttrs (_: v: v != null) (props // {{ name = rname; }})
      ) {cfg_attr};
    }}
  ];'''

    else:
        raise ValueError(f"Unknown mode: {mode}")

    return f'''\
# Generated from DSC resource schema — do not edit manually.
# Source: {source_note}
# Regenerate: {regen_cmd}
{{
  lib,
  config,
  ...
}}:
let
  cfg = config.win.dsc;
in
{{
  options.{nix_option_path} = lib.mkOption {{
    type = lib.types.attrsOf (lib.types.submodule {{
      options = {{
{options_str}
      }};
    }});
    default = {{ }};
    description = "{escape_nix(resource_description)}";
  }};

{config_block}
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="DSC manifest JSON or schema JSON file")
    parser.add_argument("--schema-json", action="store_true", help="Input is a plain JSON schema file")
    parser.add_argument("--mof", action="store_true", help="Input is a MOF schema file (.schema.mof)")
    parser.add_argument("--resource-type", help="Resource type (required with --schema-json / --mof)")
    parser.add_argument("--resource-description", default="", help="Resource description")
    parser.add_argument("--mode", choices=["native", "psdsc-wrapper", "container"], default="native")
    parser.add_argument("--wrapper-adapter", default="Microsoft.Windows/WindowsPowerShell")
    parser.add_argument("--wrapper-inner-type", help="Inner resource type for psdsc-wrapper")
    parser.add_argument("--array-prop", default="rules", help="Array property for container mode")
    parser.add_argument("--container-name", help="DSC resource name for container mode")
    parser.add_argument("--option-path", help="Override Nix option path (dot-separated)")
    parser.add_argument("--key-prop", help="Property auto-set from attrset key (excluded from options)")
    parser.add_argument(
        "--instance-schema",
        help=(
            "Path to a DSC v3 `document.resource.json` schema. Author-settable "
            "framework-level fields (e.g. `dependsOn`) are surfaced as Nix "
            "options and threaded into the emitted resource record. Required "
            "for native and psdsc-wrapper modes; ignored in container mode."
        ),
    )
    args = parser.parse_args()

    print(generate_module(args), end="")


if __name__ == "__main__":
    main()
