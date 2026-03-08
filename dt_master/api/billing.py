import frappe
from frappe.utils.pdf import get_pdf


@frappe.whitelist()
def download_invoice_pdf(invoice_name,prt_format):

    # temporarily elevate permissions
    original_user = frappe.session.user
    frappe.set_user("Administrator")

    try:
        html = frappe.get_print("Sales Invoice", invoice_name, prt_format)
        pdf = get_pdf(html)

        frappe.local.response.filename = f"{invoice_name}.pdf"
        frappe.local.response.filecontent = pdf
        frappe.local.response.type = "download"

    finally:
        frappe.set_user(original_user)