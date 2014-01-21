local computer = require("computer")
local unicode = require("unicode")

local buffer = {}

function buffer.new(mode, stream)
  local result = {
    mode = mode or "r",
    stream = stream,
    buffer = "",
    bufferSize = math.max(128, math.min(8 * 1024, computer.freeMemory() / 8)),
    bufferMode = "full"
  }
  local metatable = {
    __index = buffer,
    __metatable = "file"
  }
  return setmetatable(result, metatable)
end

function buffer:close()
  if string.find(self.mode, "w", 1, true) or string.find(self.mode, "a", 1, true) then
    self:flush()
  end
  return self.stream:close()
end

function buffer:flush()
  local result, reason = self.stream:write(self.buffer)
  if result then
    self.buffer = ""
  else
    if reason then
      return nil, reason
    else
      return nil, "bad file descriptor"
    end
  end

  return self
end

function buffer:lines(...)
  local args = table.pack(...)
  return function()
    local result = table.pack(self:read(table.unpack(args, 1, args.n)))
    if not result[1] and result[2] then
      error(result[2])
    end
    return table.unpack(result, 1, result.n)
  end
end

function buffer:read(...)
  local function readChunk()
    local result, reason = self.stream:read(self.bufferSize)
    if result then
      self.buffer = self.buffer .. result
      return self
    else -- error or eof
      return nil, reason
    end
  end

  local function readBytesOrChars(n)
    n = math.max(n, 0)
    local len, sub
    if string.find(self.mode, "b", 1, true) then
      len = rawlen
      sub = string.sub
    else
      len = unicode.len
      sub = unicode.sub
    end
    local buffer = ""
    repeat
      if len(self.buffer) == 0 then
        local result, reason = readChunk()
        if not result then
          if reason then
            return nil, reason
          else -- eof
            return #buffer > 0 and buffer or nil
          end
        end
      end
      local left = n - len(buffer)
      buffer = buffer .. sub(self.buffer, 1, left)
      self.buffer = sub(self.buffer, left + 1)
    until len(buffer) == n
    return buffer
  end

  local function readLine(chop)
    local start = 1
    while true do
      local l = self.buffer:find("\n", start, true)
      if l then
        local result = self.buffer:sub(1, l + (chop and -1 or 0))
        self.buffer = self.buffer:sub(l + 1)
        return result
      else
        start = #self.buffer
        local result, reason = readChunk()
        if not result then
          if reason then
            return nil, reason
          else -- eof
            local result = #self.buffer > 0 and self.buffer or nil
            self.buffer = ""
            return result
          end
        end
      end
    end
  end

  local function readAll()
    repeat
      local result, reason = readChunk()
      if not result and reason then
        return nil, reason
      end
    until not result -- eof
    local result = self.buffer
    self.buffer = ""
    return result
  end

  local function read(n, format)
    if type(format) == "number" then
      return readBytesOrChars(format)
    else
      if type(format) ~= "string" or unicode.sub(format, 1, 1) ~= "*" then
        error("bad argument #" .. n .. " (invalid option)")
      end
      format = unicode.sub(format, 2, 2)
      if format == "n" then
        --[[ TODO ]]
        error("not implemented")
      elseif format == "l" then
        return readLine(true)
      elseif format == "L" then
        return readLine(false)
      elseif format == "a" then
        return readAll()
      else
        error("bad argument #" .. n .. " (invalid format)")
      end
    end
  end

  local results = {}
  local formats = table.pack(...)
  if formats.n == 0 then
    return readLine(true)
  end
  for i = 1, formats.n do
    local result, reason = read(i, formats[i])
    if result then
      results[i] = result
    elseif reason then
      return nil, reason
    end
  end
  return table.unpack(results, 1, formats.n)
end

function buffer:seek(whence, offset)
  whence = tostring(whence or "cur")
  assert(whence == "set" or whence == "cur" or whence == "end",
    "bad argument #1 (set, cur or end expected, got " .. whence .. ")")
  offset = offset or 0
  checkArg(2, offset, "number")
  assert(math.floor(offset) == offset, "bad argument #2 (not an integer)")

  if whence == "cur" then
    offset = offset - #self.buffer
  end
  local result, reason = self.stream:seek(whence, offset)
  if result then
    self.buffer = ""
    return result
  else
    return nil, reason
  end
end

function buffer:setvbuf(mode, size)
  mode = mode or self.bufferMode
  size = size or self.bufferSize

  assert(mode == "no" or mode == "full" or mode == "line",
    "bad argument #1 (no, full or line expected, got " .. tostring(mode) .. ")")
  assert(mode == "no" or type(size) == "number",
    "bad argument #2 (number expected, got " .. type(size) .. ")")

  self.bufferMode = mode
  self.bufferSize = size

  return self.bufferMode, self.bufferSize
end

function buffer:write(...)
  local args = table.pack(...)
  for i = 1, args.n do
    if type(args[i]) == "number" then
      args[i] = tostring(args[i])
    end
    checkArg(i, args[i], "string")
  end

  for i = 1, args.n do
    local arg = args[i]
    local result, reason

    if self.bufferMode == "full" then
      if self.bufferSize - #self.buffer < #arg then
        result, reason = self:flush()
        if not result then
          return nil, reason
        end
      end
      if #arg > self.bufferSize then
        result, reason = self.stream:write(arg)
      else
        self.buffer = self.buffer .. arg
        result = self
      end

    elseif self.bufferMode == "line" then
      local l
      repeat
        local idx = arg:find("\n", (l or 0) + 1, true)
        if idx then
          l = idx
        end
      until not idx
      if l or #arg > self.bufferSize then
        result, reason = self:flush()
        if not result then
          return nil, reason
        end
      end
      if l then
        result, reason = self.stream:write(arg:sub(1, l))
        if not result then
          return nil, reason
        end
        arg = arg:sub(l + 1)
      end
      if #arg > self.bufferSize then
        result, reason = self.stream:write(arg)
      else
        self.buffer = self.buffer .. arg
        result = self
      end

    else -- self.bufferMode == "no"
      result, reason = self.stream:write(arg)
    end

    if not result then
      return nil, reason
    end
  end

  return self
end

return buffer