Config = {}

-- SnapDuty 2.0.0 (Live Roster + High Command UI)

Config.Departments = {
    sast = {
        label = "SAST",
        blipIcon = 60,
        blipColor = 29,
        blipScale = 0.85,
        shortRange = true,
        webhook = "https://discord.com/api/webhooks/1391877203859603506/8UkZV8-0kK28QXneZYPCNmeBVMLUTJtHJcyJeCarZZgU_LZDFVSwN5FTaBZX8nb05LVE",
        thumbnail = "https://example.com/images/police.png",
        jobNames = { "sast" }
    },
    fib = {
        label = "FIB",
        blipIcon = 60,
        blipColor = 40,
        blipScale = 0.85,
        shortRange = true,
        webhook = "https://discord.com/api/webhooks/1391878047551983817/jJj2I3g0MmOFWjSEIRHyoGgp3Q7zdWhX84hcSIa2eWr1A_ACTR669sKK8SI0bPSsQxsM",
        thumbnail = "https://example.com/images/police.png",
        jobNames = { "fib" }
    },
    ems = {
        label = "EMS",
        blipIcon = 61,
        blipColor = 1,
        blipScale = 0.85,
        shortRange = true,
        webhook = "https://discord.com/api/webhooks/1391879080290422915/YfNHm9-Qx3Rl14jrXuzU1vCeNcMHSVh6QhHXLU_jbk56Qz6k1p7hEya3NQGagEQfwCb9",
        thumbnail = "https://example.com/images/ems.png",
        jobNames = { "ambulance", "ems" }
    },
    safd = {
        label = "SAFD",
        blipIcon = 61,
        blipColor = 1,
        blipScale = 0.85,
        shortRange = true,
        webhook = "YOUR_SAFD_WEBHOOK",
        thumbnail = "https://example.com/images/fire.png",
        jobNames = { "fire", "safd" }
    }
}

-- Command to toggle duty
Config.DutyCommand = "duty"

-- Command to open High Command panel
Config.HCCommand = "sdhc"

-- QBCore permissions that are considered "Server Staff".
-- These are the same strings you use with qb-core permissions (.admin / .god).
Config.StaffPerms = { "admin", "god" }

Config.RequireDeptSelectionWhenAmbiguous = true

-- If someone has no callsign yet, prompt them the first time they go on duty.
Config.RequireCallsign = true
