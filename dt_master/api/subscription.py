import frappe

@frappe.whitelist()
def get_available_plans(limit=12, offset=0):

    plans = frappe.get_all(
        "Subscription Plan",
        fields=[
            "name",
            "plan_name",
            "cost",
            "currency",
            "billing_interval",
            "billing_interval_count",
            "price_determination"
        ],
        limit=limit,
        start=offset,
        order_by="cost asc"
    )

    result = []

    for plan in plans:

        profile = frappe.get_doc(
            "Capability Profile",
            {"subscription_plan": plan.name}
        ) if frappe.db.exists(
            "Capability Profile",
            {"subscription_plan": plan.name}
        ) else None

        allowed_modules = []
        allowed_roles = []

        if profile:
            allowed_modules = [m.module for m in profile.allowed_modules]
            allowed_roles = [r.role for r in profile.allowed_roles]

        machine = None

        if profile:
            machine = frappe.get_value(
                "Machine Constraint",
                {"profile": profile.name, "active": 1},
                [
                    "cpu_cores",
                    "ram_gb",
                    "storage_gb",
                    "database_storage_gb",
                    "web_workers",
                    "background_workers",
                    "max_users",
                    "deployment_type"
                ],
                as_dict=True
            )

        result.append({
            "plan": plan,
            "capability_profile": {
                "name": profile.name if profile else None,
                "profile_name": profile.profile_name if profile else None,
                "description": profile.description if profile else None
            } if profile else None,
            "allowed_modules": allowed_modules,
            "allowed_roles": allowed_roles,
            "machine_constraints": machine
        })

    return result

@frappe.whitelist()
def get_billing_history(fqdn,limit=12, offset=0):

    subscription = frappe.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "subscription"
    )

    if not subscription:
        frappe.throw("Tenant not found")

    invoices = frappe.get_all(
        "Sales Invoice",
        filters={"subscription": subscription},
        fields=[
            "name",
            "posting_date",
            "due_date",
            "grand_total",
            "outstanding_amount",
            "currency",
            "status"
        ],
        limit=limit,
        start=offset,
        order_by="posting_date desc"
    )

    return invoices

@frappe.whitelist()
def change_subscription_plan(fqdn, plan_name):

    subscription = frappe.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "subscription"
    )

    if not subscription:
        frappe.throw("Tenant not found")

    sub = frappe.get_doc("Subscription", subscription)

    sub.subscription_plan = plan_name
    sub.save(ignore_permissions=True)

    frappe.db.commit()

    return {
        "status": "success",
        "subscription": subscription,
        "plan": plan_name
    }