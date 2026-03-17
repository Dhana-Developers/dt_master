frappe.ui.form.on("Mail Server", {

    refresh(frm) {

        if (!frm.is_new()) {
            setup_automation_buttons(frm);
        }

        setup_mail_user_buttons(frm);

    }

});



/* -----------------------------------------------------------
MAIL SERVER AUTOMATION BUTTONS
----------------------------------------------------------- */

function setup_automation_buttons(frm) {

    const status = frm.doc.status;
    const state = frm.doc.automation_state || "idle";

    const actions = {

        install_mail_stack: {
            status: ["Requested", "Failed"],
            states: ["idle", "failed"],
            method: "dt_master.api.mail_server_executor.install_mail_stack"
        },

        configure_postfix: {
            status: ["Installing"],
            states: ["installing_stack", "failed"],
            method: "dt_master.api.mail_server_executor.configure_postfix"
        },

        configure_dovecot: {
            status: ["Installing"],
            states: ["configuring_postfix", "failed"],
            method: "dt_master.api.mail_server_executor.configure_dovecot"
        },

        configure_rspamd: {
            status: ["Installing"],
            states: ["configuring_dovecot", "failed"],
            method: "dt_master.api.mail_server_executor.configure_rspamd"
        },

        configure_opendkim: {
            status: ["Installing"],
            states: ["configuring_rspamd", "failed"],
            method: "dt_master.api.mail_server_executor.configure_opendkim"
        },

        configure_dns: {
            status: ["Installing"],
            states: ["configuring_opendkim", "failed"],
            method: "dt_master.api.mail_server_executor.configure_dns"
        },

        verify_mail_server: {
            status: ["Installing"],
            states: ["configuring_dns", "failed"],
            method: "dt_master.api.mail_server_executor.verify_mail_server"
        }

    };

    Object.keys(actions).forEach(label => hide_button(frm, label));

    Object.entries(actions).forEach(([label, cfg]) => {

        const status_ok = cfg.status.includes(status);
        const state_ok = cfg.states.includes(state);

        if (status_ok && state_ok) {
            show_and_bind(frm, label, cfg.method);
        }

    });

}



/* -----------------------------------------------------------
MAIL USER ACTION BUTTONS
----------------------------------------------------------- */

function setup_mail_user_buttons(frm) {

    frm.add_custom_button("Sync Mail Users", () => {
        const dialog = create_tenant_log_dialog("Sync Mail Users");

        start_mail_log_stream(dialog, frm.doc.name);

        frappe.call({
            method: "dt_master.api.mail_server_executor.list_mail_users",
            args: {
                mail_server_name: frm.doc.name
            },
            callback() {
                frm.reload_doc();
            }
        });

    });

    frm.add_custom_button("Create Mailbox", () => {
        const dialog = create_tenant_log_dialog("Create Mailbox");

        start_mail_log_stream(dialog, frm.doc.name);

        const row = frm.fields_dict.mail_users.grid.get_selected_children()[0];

        if (!row) {
            frappe.msgprint("Select a Mail User row first");
            return;
        }

        frappe.call({
            method: "dt_master.api.mail_server_executor.add_mail_user",
            args: {
                mail_user_name: row.name
            }
        });

    });

    frm.add_custom_button("Delete Mailbox", () => {
        const dialog = create_tenant_log_dialog("Delete Mailbox");

        start_mail_log_stream(dialog, frm.doc.name);

        const row = frm.fields_dict.mail_users.grid.get_selected_children()[0];

        if (!row) {
            frappe.msgprint("Select a Mail User row first");
            return;
        }

        frappe.call({
            method: "dt_master.api.mail_server_executor.remove_mail_user",
            args: {
                mail_user_name: row.name
            }
        });

    });

    frm.add_custom_button("Update Password", () => {
        const dialog = create_tenant_log_dialog("Update Password");

        start_mail_log_stream(dialog, frm.doc.name);

        const row = frm.fields_dict.mail_users.grid.get_selected_children()[0];

        if (!row) {
            frappe.msgprint("Select a Mail User row first");
            return;
        }

        frappe.call({
            method: "dt_master.api.mail_server_executor.update_mail_user_password",
            args: {
                mail_user_name: row.name
            }
        });

    });

}



/* -----------------------------------------------------------
BUTTON HELPERS
----------------------------------------------------------- */

function show_and_bind(frm, label, method) {

    const btn = frm.get_field(label);
    if (!btn || !btn.$wrapper) return;

    btn.$wrapper.show();

    btn.$wrapper.off("click").on("click", () => {

        const dialog = create_tenant_log_dialog(label);

        start_mail_log_stream(dialog, frm.doc.name);

        frappe.call({
            method,
            args: {
                mail_server_name: frm.doc.name
            },
            callback() {
                frm.reload_doc();
            }
        });

    });

}

function create_tenant_log_dialog(title) {

    const dialog = new frappe.ui.Dialog({
        title: title.replaceAll("_"," "),
        fields: [{ fieldtype:"HTML", fieldname:"log_container" }],
        size: "large"
    });

    dialog.show();

    dialog.log_el = dialog.fields_dict.log_container.$wrapper;

    dialog.log_el.css({
        background:"#111",
        color:"#0f0",
        "font-family":"monospace",
        padding:"10px",
        height:"400px",
        "overflow-y":"scroll"
    });

    dialog.log_el.append(`<div style="color:#888">Starting remote action...</div>`);

    return dialog;
}

function start_mail_log_stream(dialog, server_name) {

    let cleared = false;

    frappe.realtime.off("mail_executor_log");

    frappe.realtime.on("mail_executor_log", data => {

        if (data.server !== server_name) return;

        if (data.line) {

            if (!cleared) {
                dialog.log_el.empty();
                cleared = true;
            }

            dialog.log_el.append(
                `<div>${frappe.utils.escape_html(data.line)}</div>`
            );

            dialog.log_el.scrollTop(dialog.log_el[0].scrollHeight);
        }

        if (data.status === "Completed") {
            dialog.log_el.append(`<div style="color:#0f0">PROCESS COMPLETED</div>`);
        }

        if (data.status === "Failed") {
            dialog.log_el.append(`<div style="color:red">PROCESS FAILED</div>`);
        }

    });
}

function hide_button(frm, label) {

    const btn = frm.get_field(label);
    if (btn && btn.$wrapper) btn.$wrapper.hide();

}