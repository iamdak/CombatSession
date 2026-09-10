-- CombatSessionViewer :: Commands

local ADDON, ns = ...

SLASH_COMBATSESSIONVIEWER1 = "/csv"

SlashCmdList["COMBATSESSIONVIEWER"] = function(input)
    local cmd, rest = strsplit(" ", strtrim(input or ""), 2)
    cmd = strlower(cmd or "")
    rest = strlower(strtrim(rest or ""))

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        ns.UI:Toggle()

    elseif cmd == "hide" or cmd == "close" then
        ns.UI:Hide()

    elseif cmd == "reset" then
        -- Placement only. There is nothing else here worth resetting: the
        -- viewer holds no data of its own.
        ns.db.point, ns.db.x, ns.db.y = "CENTER", 0, 0
        ns.db.width, ns.db.height = 1040, 620
        ns:Print("window position reset - |cffffcc00/reload|r to apply")

    -- "minimap" kept as an alias: it is what the command was called before, and
    -- a command that silently stops working is a worse trade than one extra
    -- word here. Bare "icon" toggles; on/off set it outright, which is what a
    -- macro or a written-down instruction needs.
    elseif cmd == "icon" or cmd == "minimap" then
        local shown
        if rest == "on" or rest == "show" then
            shown = ns:SetMinimapButtonShown(true)
        elseif rest == "off" or rest == "hide" then
            shown = ns:SetMinimapButtonShown(false)
        else
            shown = ns:ToggleMinimapButton()
        end
        ns:Print("minimap icon " .. (shown and "shown" or
                 "hidden - |cffffcc00/csv icon|r brings it back"))

    elseif cmd == "status" then
        local api = ns:API()
        if not api then
            ns:Print("CombatSession is not loaded")
            return
        end
        local defines = api:GetDefines()
        ns:Print(("v%s | library format %s | %d session(s) viewable")
            :format(ns.VersionText(), tostring(defines and defines.VERSION),
                    #api:GetViewable()))

    else
        ns:Print("usage: /csv [show | hide | icon on|off | reset | status]")
    end
end
