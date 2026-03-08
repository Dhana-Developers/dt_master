import frappe

@frappe.whitelist()
def get_tenant_capabilities(fqdn):

    fqdn = fqdn.split(":")[0]

    # 1. Resolve tenant
    tenant = frappe.get_value(
        "Tenant Site",
        {
            "fqdn": fqdn,
            "status": ["in", ["Requested", "Active"]]
        },
        ["subscription", "status"],
        as_dict=True
    )

    if not tenant:
        frappe.throw("Invalid or inactive tenant")

    # 2. Load subscription
    subscription = frappe.get_doc("Subscription", tenant.subscription)

    if not subscription.plans:
        frappe.throw("Subscription has no plans")

    # 3. Pick primary plan
    plan_name = subscription.plans[0].plan

    # 4. Resolve capability profile
    profile_name = frappe.get_value(
        "Capability Profile",
        {"subscription_plan": plan_name},
        "name"
    )

    if not profile_name:
        frappe.throw(f"No capability profile linked to plan {plan_name}")

    profile = frappe.get_doc("Capability Profile", profile_name)

    # 5. Machine constraint
    machine = frappe.get_value(
        "Machine Constraint",
        {
            "profile": profile.name,
            "active": 1
        },
        "*",
        as_dict=True
    )

    # 6. Base response (unchanged variables)
    response = {
        "subscription_status": subscription.status,
        "trial_period_end": subscription.trial_period_end,
        "end_date": subscription.end_date,
        "subscription_plan": plan_name,
        "capability_profile": profile.name,
        "allowed_roles": [r.role for r in profile.allowed_roles],
        "allowed_modules": [m.module for m in profile.allowed_modules],
    }

    # 7. Machine properties dictionary
    if machine:
        response["machine_properties"] = {
            "cpu_cores": machine.cpu_cores,
            "cpu_quota_percent": machine.cpu_quota_percent,
            "cpu_shares": machine.cpu_shares,
            "ram_gb": machine.ram_gb,
            "ram_reservation_gb": machine.ram_reservation_gb,
            "swap_limit_gb": machine.swap_limit_gb,
            "storage_gb": machine.storage_gb,
            "database_storage_gb": machine.database_storage_gb,
            "backup_storage_gb": machine.backup_storage_gb,
            "web_workers": machine.web_workers,
            "background_workers": machine.background_workers,
            "scheduler_workers": machine.scheduler_workers,
            "max_connections": machine.max_connections,
            "query_timeout_seconds": machine.query_timeout_seconds,
            "max_query_memory_mb": machine.max_query_memory_mb,
            "max_users": machine.max_users,
            "max_api_requests_per_minute": machine.max_api_requests_per_minute,
            "max_background_jobs": machine.max_background_jobs,
            "max_file_upload_mb": machine.max_file_upload_mb,
            "container_image": machine.container_image,
            "container_template": machine.container_template,
            "node_selector": machine.node_selector,
            "deployment_type": machine.deployment_type,
        }

    return response