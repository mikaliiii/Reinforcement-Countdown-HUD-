-- 只读进程内存访问层 / Read-only process memory access.
--
-- 本模块只声明四个 Windows API：
--   GetModuleHandleA, GetCurrentProcess, ReadProcessMemory, GetTickCount64
-- 全文没有 WriteProcessMemory / VirtualProtect / VirtualAlloc，
-- 构建脚本会静态检查这一点并在命中时拒绝打包。
--
-- 每一次读取都先校验地址范围，失败返回 nil 而不是抛错，因此可以安全地
-- 探测"这个指针指向哪里"这种投机性问题。
--
-- 来源：Reinforcement Radar (MIT, superSizzzz) 的 src/read_api.lua。
return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), '需要 Windows x64 / Windows x64 is required')

    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        uint64_t GetTickCount64(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer,
                              size_t size, size_t *read);
    ]]

    local kernel = ffi.load('kernel32')
    local process = kernel.GetCurrentProcess()

    local u32buf = ffi.new('uint32_t[1]')
    local u64buf = ffi.new('uint64_t[1]')
    local f32buf = ffi.new('float[1]')

    local MIN_ADDRESS = 65536
    local MAX_ADDRESS = 140737488355328    -- 0x800000000000，用户态上限
    local MAX_READ = 2097152               -- 2 MiB，与已验证的读取层一致

    local api = {}

    -- 已加载模块的基址；传入 nil 取主可执行文件。取不到返回 nil。
    --
    -- GetModuleHandleA 返回的是不透明 void* cdata，而 tonumber() 不接受指针
    -- cdata（直接返回 nil）。必须先 cast 成 uintptr_t 才能转换。
    -- 这一点在实机上验证过：句柄本身正常（GetLastError()==0），只有转换失败。
    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end

    function api.time()
        return tonumber(kernel.GetTickCount64()) / 1000
    end

    -- 读取 size 字节。地址未映射或只有部分可读时返回 nil。
    function api.read(address, size)
        if type(address) ~= 'number' or type(size) ~= 'number' then return nil end
        if address < MIN_ADDRESS or address >= MAX_ADDRESS then return nil end
        if size < 1 or size > MAX_READ then return nil end
        local buffer = ffi.new('uint8_t[?]', size)
        local count = ffi.new('size_t[1]')
        local ok = kernel.ReadProcessMemory(process, ffi.cast('const void *', address),
                                            buffer, size, count)
        if ok == 0 or tonumber(count[0]) ~= size then return nil end
        return ffi.string(buffer, size)
    end

    local function scalar(address, buffer, size)
        if type(address) ~= 'number' then return nil end
        local bytes = api.read(address, size)
        if not bytes then return nil end
        ffi.copy(buffer, bytes, size)
        return tonumber(buffer[0])
    end

    function api.u8(address)
        local bytes = api.read(address, 1)
        if not bytes then return nil end
        return bytes:byte(1)
    end

    function api.u32(address) return scalar(address, u32buf, 4) end
    function api.f32(address) return scalar(address, f32buf, 4) end
    function api.u64(address) return scalar(address, u64buf, 8) end

    -- 读取 address 处存放的指针，拒绝空值与不合理的值。
    function api.pointer(address)
        local value = api.u64(address)
        if value == nil or value < MIN_ADDRESS or value >= MAX_ADDRESS then return nil end
        return value
    end

    -- 有限浮点数是原始字段最省的合理性检查。
    function api.finite(value, maximum)
        if type(value) ~= 'number' then return false end
        if value ~= value then return false end            -- NaN
        return math.abs(value) <= (maximum or 1000000)
    end

    return api
end
