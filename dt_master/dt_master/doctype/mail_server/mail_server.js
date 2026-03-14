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

        frappe.call({
            method,
            args: {
                mail_server_name: frm.doc.name
            },
            freeze: true,
            freeze_message: `${label.replace("_"," ")}…`,
            callback() {
                frm.reload_doc();
            }
        });

    });

}

function hide_button(frm, label) {

    const btn = frm.get_field(label);
    if (btn && btn.$wrapper) btn.$wrapper.hide();

}