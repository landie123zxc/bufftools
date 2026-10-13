BuffTools
=========

Inject:

getgenv().BuffToolsKey = "BUFF-XXXX-XXXX" -- optional, skips prompt if valid
loadstring(game:HttpGet("https://raw.githubusercontent.com/landie123zxc/bufftools/main/BuffTools.lua"))()

Keys
----
Edit keys.json on this repo (raw URL is checked on inject).

Examples:

{
  "keys": {
    "BUFF-AAAA-1111": true,
    "BUFF-BBBB-2222": {
      "note": "buyer name",
      "expires": 1893456000,
      "hwid": "optional-client-id",
      "userIds": [123456789]
    },
    "BUFF-DEAD-0000": { "disabled": true }
  }
}

- expires = unix timestamp (optional)
- hwid = RbxAnalyticsService client id (optional lock)
- userIds = only these Roblox user ids (optional)
- Owner bypass: getgenv().BuffToolsSkipAuth = true

Valid key is saved to executor file bufftools_key.txt.
