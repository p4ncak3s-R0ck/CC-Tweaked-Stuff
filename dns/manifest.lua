return {
    manifestVersion = 1,
    name = "dns",
    version = "2.0.0",
    type = "library",
    description = "Authenticated DNS over Rednet",
    files = { ["src/dns.lua"] = "dns.lua" },
    modules = { dns = "dns.lua" },
    dependencies = {},
}
