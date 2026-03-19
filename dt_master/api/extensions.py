
import frappe
from frappe.utils import get_url


def version_tuple(v):
    return tuple(int(x) for x in v.split("."))

@frappe.whitelist(allow_guest=False)
def get_extensions(tab=None, limit=12, offset=0, fqdn=None, frappe_major=None, frappe_minor=None, frappe_patch=None):

    limit = int(limit)
    offset = int(offset)
    frappe_major = int(frappe_major) if frappe_major else None
    frappe_minor = int(frappe_minor) if frappe_minor else None
    frappe_patch = int(frappe_patch) if frappe_patch else None

    tenant_version = (frappe_major, frappe_minor, frappe_patch)

    filters = {"status": "Approved","visibility": "Public"}

    extensions = frappe.get_all(
        "Extension",
        fields=[
            "name",
            "extension_name",
            "title",
            "publisher",
            "short_description",
            "icon",
            "visibility",
            "pricing_model",
            "price_type",
            "price_amount",
            "security_reviewed"
        ],
        filters=filters,
        order_by="creation desc",
        limit=limit,
        start=offset
    )

    # -------------------------------------------------
    # GET CURRENT TENANT SITE
    # -------------------------------------------------

    tenant_site_name = frappe.db.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "name"
    )

    if not tenant_site_name:
        frappe.throw("Tenant Site not found for fqdn")

    tenant_site = frappe.get_doc("Tenant Site", tenant_site_name)

    # Build lookup map for fast access
    installed_apps_map = {
        row.extension: row
        for row in tenant_site.installed_apps
        if row.extension
    }

    result = []

    for ext in extensions:

        # -------------------------------------------------
        # LATEST VERSION
        # -------------------------------------------------

        versions = frappe.get_all(
                        "Extension Version",
                        filters={
                            "extension": ext.name,
                            "status": "Approved"
                        },
                        fields=["version", "deprecated", "frappe_min", "frappe_max"],
                        order_by="creation desc"
                    )

        latest_version = None

        for v in versions:

            min_v = version_tuple(v.frappe_min) if v.frappe_min else None
            max_v = version_tuple(v.frappe_max) if v.frappe_max else None

            if (not min_v or tenant_version >= min_v) and (not max_v or tenant_version <= max_v):
                latest_version = v
                break

        # IMPORTANT
        if not latest_version:
            continue

        # -------------------------------------------------
        # TENANT INSTALLED APP (FROM CHILD TABLE)
        # -------------------------------------------------

        record = installed_apps_map.get(ext.name)

        # ----- INSTALL STATE LOGIC -----

        if not record:
            install_state = "not_present"
            installed_version = None
            is_installed = False

        elif record.status == "Installed":
            install_state = "installed"
            installed_version = record.installed_version
            is_installed = True

        elif record.status == "Uninstalled":
            install_state = "uninstalled"
            installed_version = record.installed_version
            is_installed = False

        elif record.status == "Failed":
            install_state = "failed"
            installed_version = record.installed_version
            is_installed = False

        else:
            install_state = "unknown"
            installed_version = record.installed_version
            is_installed = False

        # ----- VERSION LOGIC -----

        latest_version_number = latest_version.version if latest_version else None
        deprecated = latest_version.deprecated if latest_version else False

        upgradable = False

        if install_state == "installed" and record.target_version and installed_version:

            upgradable = version_tuple(record.target_version) > version_tuple(installed_version)

        # ----- ICON URL -----

        icon_url = get_url(ext.icon) if ext.icon else None
        item = {
            "name": ext.name,
            "title": ext.title,
            "publisher": ext.publisher,
            "short_description": ext.short_description,
            "description": ext.description,
            "icon": icon_url,
            "visibility": ext.visibility,
            "pricing_model": ext.pricing_model,
            "price_type": ext.price_type,
            "price_amount": ext.price_amount,
            "security_reviewed": ext.security_reviewed,

            # Keep frontend compatibility
            "installed": is_installed,
            "install_state": install_state,

            "installed_version": installed_version,
            "latest_version": latest_version_number,
            "min_frappe_version": latest_version.frappe_min if latest_version else None,
            "max_frappe_version": latest_version.frappe_max if latest_version else None,
            "upgradable": upgradable,
            "deprecated": deprecated,
        }

        result.append(item)

    # -------------------------------------------------
    # TAB FILTERING
    # -------------------------------------------------

    if tab == "marketplace":
        result = [
            r for r in result
            if r["visibility"] == "Public"
            and r["install_state"] in ("not_present", "failed")
        ]

    elif tab == "installed":
        result = [
            r for r in result
            if r["install_state"] == "installed"
            and r["visibility"] == "Public"
        ]

    elif tab == "uninstalled":
        result = [
            r for r in result
            if r["install_state"] == "uninstalled"
            and r["visibility"] == "Public"
        ]
    return result
