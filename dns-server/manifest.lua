return {
    manifestVersion = 1,
    name = "dns-server",
    version = "2.0.0",
    type = "application",
    entry = "server.lua",
    files = { ["server.lua"] = "server.lua" },
    dependencies = { dns = "^2.0.0" },
}
