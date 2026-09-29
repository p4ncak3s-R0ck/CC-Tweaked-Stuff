return {
    manifestVersion = 1,
    name = "dns-records",
    version = "1.0.0",
    type = "application",
    entry = "main.lua",
    repositories = {
        default = { github = "p4ncak3s-R0ck/CC-Tweaked-Stuff", ref = "main" },
    },
    dependencies = { dns = "^2.0.0" },
}
