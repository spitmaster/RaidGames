-- LibStub is a simple versioning stub meant for use in Libraries.
-- http://www.wowace.com/wiki/LibStub for more info
-- LibStub is hereby placed in the Public Domain
-- Credits: Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke
--
-- 来源：社区标准版 LibStub r2（Public Domain），原样嵌入。
-- 我们不依赖大脚，因此自带 LibStub，供内嵌的 LibDeflate / LibSerialize 注册与取用：
--   local LibDeflate   = LibStub("LibDeflate")
--   local LibSerialize = LibStub("LibSerialize")
-- 若环境（如某些插件/大脚整合包）已有更高版 LibStub，则让位、复用对方实例。
local LIBSTUB_MAJOR, LIBSTUB_MINOR = "LibStub", 2
local LibStub = _G[LIBSTUB_MAJOR]

if not LibStub or LibStub.minor < LIBSTUB_MINOR then
    LibStub = LibStub or { libs = {}, minors = {} }
    _G[LIBSTUB_MAJOR] = LibStub
    LibStub.minor = LIBSTUB_MINOR

    function LibStub:NewLibrary(major, minor)
        assert(type(major) == "string", "Bad argument #1 to `NewLibrary' (string expected)")
        minor = assert(tonumber(strmatch(minor, "%d+")), "Minor version must either be a number or contain a number.")

        local oldminor = self.minors[major]
        if oldminor and oldminor >= minor then return nil end
        self.minors[major], self.libs[major] = minor, self.libs[major] or {}
        return self.libs[major], oldminor
    end

    function LibStub:GetLibrary(major, silent)
        if not self.libs[major] and not silent then
            error(("Cannot find a library instance of %q."):format(tostring(major)), 2)
        end
        return self.libs[major], self.minors[major]
    end

    function LibStub:IterateLibraries() return pairs(self.libs) end

    setmetatable(LibStub, { __call = LibStub.GetLibrary })
end
