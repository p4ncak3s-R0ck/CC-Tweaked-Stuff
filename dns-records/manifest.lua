return {
    manifestVersion = 1,
    name = "dns-records",
    version = "1.0.0",
    type = "application",
    description = "Authenticated DNS record administration",
    entry = "dns-records.lua",
    files = { ["main.lua"] = "dns-records.lua" },
    dependencies = { dns = "^2.0.0" },
}
