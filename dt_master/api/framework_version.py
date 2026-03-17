# dt_master/api/framework_version.py

import json
import re

import frappe


@frappe.whitelist()
def get_dependencies_preview(source_version):
    deps = frappe.get_all(
        "Framework Version Dependency",
        filters={
            "framework_version": source_version,
            "enabled": 1
        },
        fields=["dependency", "install_order"]
    )

    # Exact match
    order_map = {d.dependency: d.install_order for d in deps}

    # Family map (python, node, etc.)
    family_order_map = {}

    def get_family(name):
        if name.startswith("python"):
            return "python"
        if name.startswith("node") or name.startswith("nodejs"):
            return "node"
        return None

    for d in deps:
        family = get_family(d.dependency)
        if family and family not in family_order_map:
            family_order_map[family] = d.install_order

    # Base deps
    base_deps = []
    for d in deps:
        dep_doc = frappe.get_doc("System Dependency", d.dependency)

        if dep_doc.dependency_group not in ["python", "node"]:
            base_deps.append({
                "dependency": d.dependency,
                "install_order": d.install_order
            })

    # Fetch ALL runtime deps
    python_all = frappe.get_all(
        "System Dependency",
        filters={"dependency_group": "python"},
        fields=["name"]
    )

    node_all = frappe.get_all(
        "System Dependency",
        filters={"dependency_group": "node"},
        fields=["name"]
    )

    def resolve_order(dep_name):
        # 1. exact match
        if dep_name in order_map:
            return order_map[dep_name]

        # 2. fallback by family
        family = get_family(dep_name)
        if family and family in family_order_map:
            return family_order_map[family]

        # 3. fallback default
        return 0

    def attach_order(dep_list):
        return [
            {
                "dependency": d.name,
                "install_order": resolve_order(d.name)
            }
            for d in dep_list
        ]

    return {
        "base_deps": base_deps,
        "python_deps": attach_order(python_all),
        "node_deps": attach_order(node_all)
    }

@frappe.whitelist()
def apply_selected_dependencies(target_version, dependencies):
    if isinstance(dependencies, str):
        dependencies = json.loads(dependencies)

    for d in dependencies:
        existing = frappe.db.exists(
            "Framework Version Dependency",
            {
                "framework_version": target_version,
                "dependency": d["dependency"]
            }
        )

        if existing:
            doc = frappe.get_doc("Framework Version Dependency", existing)
            doc.install_order = d.get("install_order", doc.install_order)
            doc.enabled = 1
            doc.save()
        else:
            frappe.get_doc({
                "doctype": "Framework Version Dependency",
                "framework_version": target_version,
                "dependency": d["dependency"],
                "enabled": 1,
                "install_order": d.get("install_order", 0)
            }).insert()

    return {"status": "success"}