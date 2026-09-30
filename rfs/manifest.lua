return {
    manifestVersion=1, name="rfs", version="0.1.0", type="library",
    description="Independent Rednet file sharing, transfers, revisions and synchronization",
    files={
        ["src/rfs.lua"]="init.lua",
        ["src/rfs_common.lua"]="rfs_common.lua",
        ["src/rfs_crypto.lua"]="rfs_crypto.lua",
        ["src/rfs_server.lua"]="rfs_server.lua",
    },
    modules={rfs="init.lua"},
    dependencies={},
}
