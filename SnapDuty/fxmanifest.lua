fx_version 'cerulean'
game 'gta5'

author 'Goober'
description 'SnapDuty - Live Blips, Duty System, and Live Roster'
version '2.1.1'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'client/*.lua'
}

server_scripts {
    'server/migrations.lua',
    'server/*.lua'
}
