pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Mahina
import Qub

ColumnLayout {
    id: root

    property var  initialTheme: ({})
    property bool isEditing:    false

    signal saved(var draft)
    signal cancelled()

    // ── Internal state ────────────────────────────────────────────────────────
    property var _draft: ({})

    function _makeDefaults(): var {
        return {
            name: "",
            primary: "#2196E8", primaryHover: "#1A7CC7",
            primaryActive: "#1565A8", primarySubtle: "#E3F4FC",
            textOnPrimary: "#FFFFFF",
            success: "#59A14F", successSubtle: "#EEF8ED",
            warning: "#F28E2B", warningSubtle: "#FEF4E7",
            error:   "#E15759", errorSubtle:   "#FEF0F0",
            info:    "#2196E8", infoSubtle:    "#EFF7FE",
            light: {
                background: "#EDEEF6", panel: "#F4F4FA",
                surface: "#FFFFFF", surfaceVariant: "#F8F8FD",
                overlay: "#00000040", border: "#E2E5F0",
                borderStrong: "#C8CEDF", textPrimary: "#1E2030",
                textSecondary: "#697180", textDisabled: "#9AA3AF",
                shadowColor: "#1E203014"
            },
            dark: {
                background: "#151922", panel: "#171D27",
                surface: "#1E2430", surfaceVariant: "#222A36",
                overlay: "#00000066", border: "#313B4C",
                borderStrong: "#475569", textPrimary: "#F4F7FB",
                textSecondary: "#AAB4C4", textDisabled: "#7F8A9A",
                shadowColor: "#0000003D"
            }
        }
    }

    function _init(): void {
        const src = (typeof initialTheme === "object" && Object.keys(initialTheme).length > 0)
                    ? initialTheme : _makeDefaults()
        _draft = JSON.parse(JSON.stringify(src))
        _nameInput.text = _draft.name || ""
    }

    function _set(key: var, value: var): void {
        const d = JSON.parse(JSON.stringify(_draft))
        d[key] = value
        _draft = d
        Theme.load(_draft)
    }

    function _setLight(key: var, value: var): void {
        const d = JSON.parse(JSON.stringify(_draft))
        if (!d.light) d.light = {}
        d.light[key] = value
        _draft = d
        Theme.load(_draft)
    }

    function _setDark(key: var, value: var): void {
        const d = JSON.parse(JSON.stringify(_draft))
        if (!d.dark) d.dark = {}
        d.dark[key] = value
        _draft = d
        Theme.load(_draft)
    }

    function _colorStr(c: var): var { return c.toString() }

    Component.onCompleted:    _init()
    onInitialThemeChanged:    _init()

    spacing: 16

    // ── Name ─────────────────────────────────────────────────────────────────
    Input {
        id: _nameInput
        label: "Name"
        placeholderText: "My Theme"
        Layout.fillWidth: true
        onTextChanged: {
            const d = JSON.parse(JSON.stringify(root._draft))
            d.name = text
            root._draft = d
        }
    }

    // ── Section label helper ──────────────────────────────────────────────────
    component SectionLabel: Text {
        color: Theme.textDisabled
        font.family:      Theme.fontFamily
        font.pixelSize:   Theme.textXs
        font.weight:      Theme.weightSemibold
        font.letterSpacing: 1.5
    }

    // ── PRIMARY PALETTE ───────────────────────────────────────────────────────
    SectionLabel { text: "PRIMARY PALETTE" }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 12
        rowSpacing: 10

        ColorPicker {
            label: "Primary"
            color: root._draft.primary || "#2196E8"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("primary", root._colorStr(c))
        }
        ColorPicker {
            label: "Primary Hover"
            color: root._draft.primaryHover || "#1A7CC7"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("primaryHover", root._colorStr(c))
        }
        ColorPicker {
            label: "Primary Active"
            color: root._draft.primaryActive || "#1565A8"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("primaryActive", root._colorStr(c))
        }
        ColorPicker {
            label: "Primary Subtle"
            color: root._draft.primarySubtle || "#E3F4FC"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("primarySubtle", root._colorStr(c))
        }
        ColorPicker {
            label: "Text on Primary"
            color: root._draft.textOnPrimary || "#FFFFFF"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("textOnPrimary", root._colorStr(c))
        }
        Item { Layout.fillWidth: true }
    }

    // ── STATUS COLORS ─────────────────────────────────────────────────────────
    SectionLabel { text: "STATUS COLORS" }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 12
        rowSpacing: 10

        ColorPicker {
            label: "Success"
            color: root._draft.success || "#59A14F"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("success", root._colorStr(c))
        }
        ColorPicker {
            label: "Success Subtle"
            color: root._draft.successSubtle || "#EEF8ED"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("successSubtle", root._colorStr(c))
        }
        ColorPicker {
            label: "Warning"
            color: root._draft.warning || "#F28E2B"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("warning", root._colorStr(c))
        }
        ColorPicker {
            label: "Warning Subtle"
            color: root._draft.warningSubtle || "#FEF4E7"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("warningSubtle", root._colorStr(c))
        }
        ColorPicker {
            label: "Error"
            color: root._draft.error || "#E15759"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("error", root._colorStr(c))
        }
        ColorPicker {
            label: "Error Subtle"
            color: root._draft.errorSubtle || "#FEF0F0"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("errorSubtle", root._colorStr(c))
        }
        ColorPicker {
            label: "Info"
            color: root._draft.info || "#2196E8"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("info", root._colorStr(c))
        }
        ColorPicker {
            label: "Info Subtle"
            color: root._draft.infoSubtle || "#EFF7FE"
            Layout.fillWidth: true
            onColorPicked: (c) => root._set("infoSubtle", root._colorStr(c))
        }
    }

    // ── LIGHT MODE ────────────────────────────────────────────────────────────
    SectionLabel { text: "LIGHT MODE" }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 12
        rowSpacing: 10

        ColorPicker {
            label: "Background"
            color: (root._draft.light && root._draft.light.background) || "#EDEEF6"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("background", root._colorStr(c))
        }
        ColorPicker {
            label: "Panel"
            color: (root._draft.light && root._draft.light.panel) || "#F4F4FA"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("panel", root._colorStr(c))
        }
        ColorPicker {
            label: "Surface"
            color: (root._draft.light && root._draft.light.surface) || "#FFFFFF"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("surface", root._colorStr(c))
        }
        ColorPicker {
            label: "Surface Variant"
            color: (root._draft.light && root._draft.light.surfaceVariant) || "#F8F8FD"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("surfaceVariant", root._colorStr(c))
        }
        ColorPicker {
            label: "Border"
            color: (root._draft.light && root._draft.light.border) || "#E2E5F0"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("border", root._colorStr(c))
        }
        ColorPicker {
            label: "Border Strong"
            color: (root._draft.light && root._draft.light.borderStrong) || "#C8CEDF"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("borderStrong", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Primary"
            color: (root._draft.light && root._draft.light.textPrimary) || "#1E2030"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("textPrimary", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Secondary"
            color: (root._draft.light && root._draft.light.textSecondary) || "#697180"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("textSecondary", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Disabled"
            color: (root._draft.light && root._draft.light.textDisabled) || "#9AA3AF"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setLight("textDisabled", root._colorStr(c))
        }
        Item { Layout.fillWidth: true }
    }

    // ── DARK MODE ─────────────────────────────────────────────────────────────
    SectionLabel { text: "DARK MODE" }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 12
        rowSpacing: 10

        ColorPicker {
            label: "Background"
            color: (root._draft.dark && root._draft.dark.background) || "#151922"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("background", root._colorStr(c))
        }
        ColorPicker {
            label: "Panel"
            color: (root._draft.dark && root._draft.dark.panel) || "#171D27"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("panel", root._colorStr(c))
        }
        ColorPicker {
            label: "Surface"
            color: (root._draft.dark && root._draft.dark.surface) || "#1E2430"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("surface", root._colorStr(c))
        }
        ColorPicker {
            label: "Surface Variant"
            color: (root._draft.dark && root._draft.dark.surfaceVariant) || "#222A36"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("surfaceVariant", root._colorStr(c))
        }
        ColorPicker {
            label: "Border"
            color: (root._draft.dark && root._draft.dark.border) || "#313B4C"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("border", root._colorStr(c))
        }
        ColorPicker {
            label: "Border Strong"
            color: (root._draft.dark && root._draft.dark.borderStrong) || "#475569"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("borderStrong", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Primary"
            color: (root._draft.dark && root._draft.dark.textPrimary) || "#F4F7FB"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("textPrimary", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Secondary"
            color: (root._draft.dark && root._draft.dark.textSecondary) || "#AAB4C4"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("textSecondary", root._colorStr(c))
        }
        ColorPicker {
            label: "Text Disabled"
            color: (root._draft.dark && root._draft.dark.textDisabled) || "#7F8A9A"
            Layout.fillWidth: true
            onColorPicked: (c) => root._setDark("textDisabled", root._colorStr(c))
        }
        Item { Layout.fillWidth: true }
    }

    Divider {}

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Item { Layout.fillWidth: true }

        Button {
            text: "Cancel"
            variant: Button.Variant.Ghost
            onClicked: {
                Theme.reset()
                Theme.load(ThemeManager.activeThemeColors())
                root.cancelled()
            }
        }

        Button {
            text: root.isEditing ? "Update" : "Save"
            variant: Button.Variant.Filled
            enabled: root._draft.name && root._draft.name.trim() !== ""
            onClicked: root.saved(root._draft)
        }
    }
}
