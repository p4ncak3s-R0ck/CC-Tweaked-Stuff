return {
    manifestVersion=1, name="updater", version="0.1.0", type="library",
    description="Single-file root updates through public DNS SRV discovery and RFS",
    files={["src/updater.lua"]="updater.lua"}, modules={updater="updater.lua"},
    dependencies={dns="^2.0.0",rfs="^0.1.0"},
}
