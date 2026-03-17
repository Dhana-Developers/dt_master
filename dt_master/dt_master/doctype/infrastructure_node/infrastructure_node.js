frappe.ui.form.on("Infrastructure Node", {
    refresh(frm) {
        if (frm.is_new()) return;

        const { status, state } = frm.doc;

        const actions = {
            install_dependencies: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["SSH Ready","Error"],
                method: "dt_master.api.infrastructure_node.install_dependencies"
            },

            install_bench: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Deps Installed","Error"],
                method: "dt_master.api.infrastructure_node.install_bench"
            },

            initialize_project: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Project Installed","Error"],
                method: "dt_master.api.infrastructure_node.init_project"
            },

            prepare_project: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Initialized","Error"],
                method: "dt_master.api.infrastructure_node.prepare_production"
            },

            start_project: {
                statuses: ["Active", "Maintenance"],
                states: ["Healthy", "Stopped"],
                method: "dt_master.api.infrastructure_node.start_project"
            },

            stop_project: {
                statuses: ["Active", "Maintenance"],
                states: ["Running"],
                method: "dt_master.api.infrastructure_node.stop_project"
            },

            check_system_status: {
                statuses: ["Provisioning", "Active", "Maintenance"],
                states: ["SSH Ready", "Healthy", "Running", "Stopped"],
                method: "dt_master.api.infrastructure_node.verify_production"
            }
        };

        // 1. Hard reset UI
        Object.keys(actions).forEach(label => hide_button(frm, label));

        // 2. Evaluate lifecycle rules
        Object.entries(actions).forEach(([label, cfg]) => {
            const status_ok = cfg.statuses.includes(status);
            const state_ok  = cfg.states.includes(state);

            if (status_ok && state_ok) {
                show_and_bind(frm, label, cfg.method);
            }
        });
    }
});

function create_log_dialog(title) {

    const dialog = new frappe.ui.Dialog({
        title: `${title.replaceAll("_"," ")}`,
        fields: [
            {
                fieldtype: "HTML",
                fieldname: "log_container"
            }
        ],
        size: "large"
    });

    dialog.show();

    dialog.log_el = dialog.fields_dict.log_container.$wrapper;

    dialog.log_el.css({
        "background": "#111",
        "color": "#0f0",
        "font-family": "monospace",
        "padding": "10px",
        "height": "400px",
        "overflow-y": "scroll"
    });

    // placeholder while waiting for first log
    dialog.log_el.append(`<div id="log-wait" style="color:#888">Starting remote script...</div>`);

    return dialog;
}

function show_and_bind(frm, label, method) {
    const btn = frm.get_field(label);
    if (!btn) return;

    btn.$wrapper.show();
    btn.$wrapper.off("click").on("click", () => {

        const dialog = create_log_dialog(label);

        // start listener first
        start_execution_log_stream(dialog);

        frappe.call({
            method,
            args: { node_name: frm.doc.name },

            callback() {
                frm.reload_doc();
            }
        });
    });
}

function start_execution_log_stream(dialog) {

    let first_line_received = false;

    frappe.realtime.on("script_execution_log", data => {

        if (data.line) {

            if (!first_line_received) {
                dialog.log_el.find("#log-wait").remove();
                first_line_received = true;
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
    if (btn) btn.$wrapper.hide();
}
