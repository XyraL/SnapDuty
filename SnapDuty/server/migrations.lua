-- SnapDuty - DB Migrations (auto-runs at resource start)
-- Supports oxmysql (preferred) and mysql-async (fallback)

local USING_OX = (GetResourceState('oxmysql') == 'started')
local DB = {}

if USING_OX then
    DB.exec = function(sql, params, cb)
        exports.oxmysql:execute(sql, params or {}, function(_)
            if cb then cb(true) end
        end)
    end
    DB.query = function(sql, params, cb)
        exports.oxmysql:query(sql, params or {}, function(rows)
            if cb then cb(rows or {}) end
        end)
    end
else
    DB.exec = function(sql, params, cb)
        MySQL.Async.execute(sql, params or {}, function(_)
            if cb then cb(true) end
        end)
    end
    DB.query = function(sql, params, cb)
        MySQL.Async.fetchAll(sql, params or {}, function(rows)
            if cb then cb(rows or {}) end
        end)
    end
end

local function ensureMeta(cb)
    DB.exec([[
        CREATE TABLE IF NOT EXISTS snapduty_meta (
            k VARCHAR(64) PRIMARY KEY,
            v VARCHAR(255) NOT NULL
        );
    ]], {}, cb)
end

local function getVersion(cb)
    DB.query("SELECT v FROM snapduty_meta WHERE k = 'schema_version' LIMIT 1", {}, function(rows)
        local v = 0
        if rows[1] and rows[1].v then v = tonumber(rows[1].v) or 0 end
        cb(v)
    end)
end

local function setVersion(v, cb)
    DB.exec([[
        INSERT INTO snapduty_meta (k, v) VALUES ('schema_version', ?)
        ON DUPLICATE KEY UPDATE v = VALUES(v);
    ]], { tostring(v) }, cb)
end

-- NOTE: Duty time tracking tables have been removed for now.
-- We keep migrations focused on roster + audit only.

local function createRosterTables(cb)
    DB.exec([[
        CREATE TABLE IF NOT EXISTS snapduty_roster (
            citizenid     VARCHAR(64) NOT NULL,
            name          VARCHAR(128) NULL,
            callsign      VARCHAR(32)  NULL,
            primary_dept  VARCHAR(32)  NULL,
            depts_json    LONGTEXT     NULL, -- JSON array of dept keys
            is_hc         TINYINT      NOT NULL DEFAULT 0,
            hc_dept       VARCHAR(32)  NULL,
            notes         VARCHAR(255) NULL,
            created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid)
        );
    ]], {}, function()
        DB.exec([[
            CREATE TABLE IF NOT EXISTS snapduty_roster_audit (
                id            INT NOT NULL AUTO_INCREMENT,
                dept          VARCHAR(32) NULL,
                actor_cid     VARCHAR(64) NULL,
                actor_name    VARCHAR(128) NULL,
                target_cid    VARCHAR(64) NULL,
                target_name   VARCHAR(128) NULL,
                action        VARCHAR(32) NOT NULL,
                payload_json  LONGTEXT NULL,
                created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (id),
                INDEX (dept),
                INDEX (actor_cid),
                INDEX (target_cid)
            );
        ]], {}, cb)
    end)
end

CreateThread(function()
    -- IMPORTANT:
    -- Some servers may have an older/partial schema_version set (or tables deleted) from
    -- previous iterations. Since all CREATE statements are IF NOT EXISTS, it is safe to
    -- always ensure the required tables exist on every start.
    ensureMeta(function()
        getVersion(function(v)
            createRosterTables(function()
                local target = 4
                if v < target then
                    setVersion(target, function()
                        print(("^2[SnapDuty]^7 DB schema ensured (v%s)." ):format(target))
                    end)
                end
            end)
        end)
    end)
end)
