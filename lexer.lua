--[[
Copyright 2018 kurzyx https://github.com/kurzyx
   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at
       http://www.apache.org/licenses/LICENSE-2.0
   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
]]

-- This lexer is heavily based on the JavaScript lexer
-- from jshint. https://github.com/jshint/jshint

local Lexer = {
    proto = {}
}
Lexer.proto.__index = Lexer.proto

Lexer.create = function(...)
    local o = setmetatable({}, Lexer.proto)
    o:__construct(...)
    return o
end

-- Token types
Lexer.TokenType = {
    EndOfFile      = 0,
    EndOfLine      = 1,
    Identifier     = 2,
    Punctuator     = 3,
    Keyword        = 4,
    Comment        = 5,
    NullLiteral    = 6,
    BooleanLiteral = 7,
    NumericLiteral = 8,
    StringLiteral  = 9,
}

-- (reserved) keywords
Lexer.Keywords = {
    'abstract',
    'break',
    'case', 'catch', 'class', 'continue',
    'def', 'do',
    'else', 'end', 'export', 'extends',
    'false', 'final', 'finally', 'for',
    'if', 'import',
    'new', --[['nil', ]] 'null',
    'object', 'override',
    'package', 'private', 'protected',
    'return',
    'sealed', 'super',
    'this', 'throw', 'trait', 'try', 'true',
    'val', 'var',
    'while', 'with'
}

local TokenType = Lexer.TokenType
local ContextType = Lexer.ContextType
local Keywords = Lexer.Keywords

local KeywordsAsKeys = {}
for _, keyword in ipairs(Lexer.Keywords) do
    KeywordsAsKeys[keyword] = true
end

--
--

local isWhitespaceCharacter = function(c)
    return c == ' ' -- space
        or c == '\t' -- tab
        or c == '\n'
        or c == '\r'
end

local isHexDigit = function(char)
    return char:match('^[0-9a-fA-F]$')
end

local isDecimalDigit = function(char)
    return char:match('^[0-9]$')
end

local isOctalDigit = function(char)
    return char:match('^[0-7]$')
end

local isBinaryDigit = function(char)
    return char == '0' or char == '1'
end

--
--

Lexer.proto.__construct = function(self, input)
    self.input = input
    self.listeners = {}
end

--[[
- Subscribe to a token event.
- You can subscribe to multiple events with one call:
-
-   lexer.on('identifier number', function(...)
-     -- ...
-   end)
]]
Lexer.proto.on = function(self, names, listener)
    for name in names:gmatch('%s*(%w+)%s*') do
        self.listeners[name] = self.listeners[name] or {}
        table.insert(self.listeners[name], listener)
    end
end

--[[
- Trigger a token event.
]]
Lexer.proto.trigger = function(self, name, ...)
    for _, listener in ipairs(self.listeners[name] or {}) do
        listener(...)
    end
end

--
--

--[[
-
]]
Lexer.proto.start = function(self)
    self:reset()

    if type(self.input) ~= 'string' then
        error("Input must be a string.")
    end

    -- Split at each new line
    for line in self.input:gmatch('([^\r\n]*)[\r\n]?') do
        table.insert(self.lines, line)
    end

    -- Pop last line (which is \0)
    self.lines[#self.lines] = nil

    self:nextLine()
end

--[[
- Resets the state of the lexer.
]]
Lexer.proto.reset = function(self)
    self.exhausted = false
    self.lines = {}
    self.line = ""
    self.lineNr = 0
    self.charNr = 0
end

--[[
- Return the next i character without actually moving the
- char pointer.
]]
Lexer.proto.peek = function(self, i)
    i = self.charNr + (i or 0)
    return self.line:sub(i, i)
end

--[[
- Move the char pointer forward i (or 1) times.
]]
Lexer.proto.skip = function(self, i)
    i = i or 1
    self.charNr = self.charNr + i
end

--[[
- Move the char pointer to after the last character of the line.
]]
Lexer.proto.skipToEOL = function(self)
    self.charNr = #self.line + 1
end

--[[
- Extract a comment out of the next sequence of characters and/or
- lines or return 'nil' if its not possible. Since comments can
- span across multiple lines this method has to move the char
- pointer.
]]
Lexer.proto.scanComments = function(self)
    local char1 = self:peek()
    local char2 = self:peek(1)

    -- End of unbegun comment... Raise an error and skip it.
    if char1 == '*' and char2 == '/' then
        self:trigger('error', {
            code = 'E018',
            line = self.lineNr,
            char = self.charNr
        })

        self:skip(2)
        return nil
    end

    local startLineNr = self.lineNr
    local startCharNr = self.charNr

    -- Comments must start either with // or /*
    if char1 ~= '/' or (char2 ~= '/' and char2 ~= '*') then
        return null
    end

    -- One-line comment
    if char2 == '/' then
        local token = {
            type        = TokenType.Comment,
            value       = self.line:sub(self.charNr + 2),
            line        = startLineNr,
            char        = startCharNr,
            isMultiline = false,
            isMalformed = false
        }

        self:skipToEOL()
        return token
    end

    -- Multi-line comment

    local value = ""
    self:skip(2)

    -- Loop till we find the end
    while true do

        local pos = self.line:find('*/')
        if pos ~= nil then
            value = value .. self.line:sub(self.charNr, pos - 1)
            self:skip(pos + 2)

            break
        end

        -- Append remaining line
        value = value .. self.line:sub(self.charNr) .. "\n"

        -- If we hit EOF and our comment is still unclosed,
        -- trigger an error and end the comment implicitly.
        if not self:nextLine() then
            self:trigger('error', {
                code = 'E017',
                line = startLineNr,
                char = startCharNr
            })

            return {
                type        = TokenType.Comment,
                value       = value,
                line        = startLineNr,
                char        = startCharNr,
                isMultiline = true,
                isMalformed = true
            }
        end
    end

    return {
        type        = TokenType.Comment,
        value       = value,
        line        = startLineNr,
        char        = startCharNr,
        isMultiline = true,
        isMalformed = false
    }
end

--[[
- Extract a string out of the next sequence of characters and/or
- lines or return 'nil' if its not possible. Since strings can
- span across multiple lines this method has to move the char
- pointer.
]]
Lexer.proto.scanStringLiteral = function(self)
    local quote = self:peek()

    -- String must start with a quote.
    if quote ~= '\'' and quote ~= '"' then
        return nil
    end

    local value = ""
    local isMultiline = false
    local startLineNr = self.lineNr
    local startCharNr = self.charNr

    self:skip()

    -- Multi-line string
    if self:peek() == quote and self:peek(1) == quote then
        isMultiline = true
        self:skip(2)
    end

    -- Check each character till ending
    while true do
        local char = self:peek()

        if char == '' then -- End of string

            -- If we hit EOL and the string is not multilined
            -- trigger an error and end the string implicitly.
            if isMultiline == false then
                self:trigger('error', {
                    code = 'E029',
                    line = startLineNr,
                    char = startCharNr
                })

                return {
                    type        = TokenType.StringLiteral,
                    value       = value,
                    line        = startLineNr,
                    char        = startCharNr,
                    isMultiline = false,
                    isMalformed = true
                }
            end

            -- If we hit EOF and our string is still unclosed,
            -- trigger an error and end the string implicitly.
            if not self:nextLine() then
                self:trigger('error', {
                    code = 'E029', -- TODO: Check this error code...
                    line = startLineNr,
                    char = startCharNr
                })

                return {
                    type        = TokenType.StringLiteral,
                    value       = value,
                    line        = startLineNr,
                    char        = startCharNr,
                    isMultiline = true,
                    isMalformed = true
                }
            end

            value = value .. '\n'
            continue
        end

        -- Special treatment for some escaped characters.
        if char == '\\' then
            local parsed = self:scanEscapeSequence()
            value = value .. parsed.char
            self:skip(parsed.skip)
            continue
        end

        -- Possible end of string
        if char == quote then

            if isMultiline == false then
                self:skip()

                break
            end

            -- Check for multi-line string ending
            if self:peek(1) == quote and self:peek(2) == quote then
                self:skip(3)

                break
            end

            -- No end of multi-line string
        end

        value = value .. char
        self:skip()
    end

    return {
        type        = TokenType.StringLiteral,
        value       = value,
        line        = startLineNr,
        char        = startCharNr,
        isMultiline = isMultiline,
        isMalformed = false
    }
end

--[[
- Assumes previously parsed character was \ (== '\\') and was not skipped.
]]
Lexer.proto.scanEscapeSequence = function(self)
    local char = self:peek(1)

    if char == '' then -- End of line
        return {
            char = '',
            skip = 1
        }
    end

    local escpadedChars = {
        ['a']  = '\\a',
        ['b']  = '\\b',
        ['f']  = '\\f',
        ['n']  = '\\n',
        ['r']  = '\\r',
        ['t']  = '\\t',
        ['v']  = '\\v',
        ['\\'] = '\\\\', 
        ['\''] = '\\\'',
        ['"']  = '\\"',
    }

    return {
        char = escpadedChars[char] or char,
        skip = 2
    }
end

--[[
- Extract a punctuator out of the next sequence of characters
- or return 'nil' if its not possible.
]]
Lexer.proto.scanPunctuator = function(self)
    local c1 = self:peek()

    if c1 == nil then -- End of line
        return nil
    end

    local _token = function(value)
        self:skip(#value)

        return {
            type = TokenType.Punctuator,
            value = value,
            line = self.lineNr,
            char = self.charNr
        }
    end

    -- Explict single-character punctuators: ( ) [ ] { } ; , : ~ ?

    if ('()[]{};,:~?'):find(c1, 1, true) then
        return _token(c1)
    end

    -- (Possible) multiple-character punctuators

    local c2 = self:peek(1)
    local c3 = self:peek(2)
    local c4 = self:peek(3)

    if c1 == '.' then

        -- Check if this is supposed to be a number
        if c2:match('[0-9]') ~= nil then
            return nil
        end

        -- ... (vararg)
        if c2 == '.' and c3 == '.' then
            return _token('...')
        end

        return _token('.')
    end

    -- 3-character punctuators: >>> <<= >>=

    if c1 == '>' and c2 == '>' and (c3 == '>' or c3 == '=') then -- >>> >>=
        return _token('>>' .. c3)
    end

    if c1 == '<' and c2 == '<' and c3 == '=' then -- <<=
        return _token('<<=')
    end

    -- 2-character punctuators: <= >= == != ++ -- << >> && ||
    -- += -= *= %= &= |= ^= /=

    if c2 == '=' and ('<>=!+-*%&|^/'):find(c1, 1, true) then -- <= >= == != += -= *= %= &= |= ^= /=
        return _token(c1 .. c2)
    end

    if c1 == c2 and ('+-<>&|'):find(c1, 1, true) then -- ++ -- << >> && ||
        return _token(c1 .. c2)
    end

    -- 1-character punctuators: < > = ! + - * % & | ^ /

    if ('<>=!+-*%&|^/'):find(c1, 1, true) then
        return _token(c1)
    end

    return nil
end

--[[
- Extract a keyword out of the next sequence of characters or
- return 'nil' if its not possible.
]]
Lexer.proto.scanKeyword = function(self)
    local p1, p2 = self.line:find('^[a-zA-Z_$][a-zA-Z0-9_$]*', self.charNr)

    if p1 == nil then
        return nil
    end

    local value = self.line:sub(p1, p2)

    if KeywordsAsKeys[value] == nil then
        return nil
    end

    local startCharNr = self.charNr

    self:skip(p2 - p1 + 1)

    return {
        type = TokenType.Keyword,
        value = value,
        line = self.lineNr,
        char = startCharNr
    }
end

--[[
- Extract an identifier out of the next sequence of
- characters or return 'nil' if its not possible. In addition,
- to Identifier this method can also produce BooleanLiteral
- (true/false) and NullLiteral (null).
]]
Lexer.proto.scanIdentifier = function(self)

end

--[[
- Extract a numeric literal out of the next sequence of
- characters or return 'nil' if its not possible.
]]
Lexer.proto.scanNumericLiteral = function(self)
    local char = self:peek()

    -- Numbers must start either with a decimal digit or a point.
    if char ~= '.' and not isDecimalDigit(char) then
        return nil
    end

    local value = ""
    local base = 10
    local isAllowedDigit = isDecimalDigit

    if char ~= '.' then
        value = char

        self:skip()
        char = self:peek()

        if value == '0' then

            -- Base-16 numbers.
            if char == 'x' or char == 'X' then
                base = 16
                isAllowedDigit = isHexDigit
            end

            -- Base-8 numbers.
            if char == 'o' or char == 'O' then
                base = 8
                isAllowedDigit = isOctalDigit
            end

            -- Base-2 numbers.
            if char == 'b' or char == 'B' then
                base = 2
                isAllowedDigit = isBinaryDigit
            end

            -- TODO: decimals with leading 0 is illegal
            value = value .. char
            self:skip()
        end

        -- Loop till the character is not a valid digit.
        while true do
            char = self:peek()

            if not isAllowedDigit(char) then
                break
            end

            value = value .. char
            self:skip()
        end

        if base ~= 10 then
            if #value == 2 then -- 0x 0o 0b
                return {
                    type = TokenType.NumericLiteral,
                    value = value,
                    isMalformed = true
                }
            end

            return {
                type = TokenType.NumericLiteral,
                value = value,
                base = base,
                isMalformed = false
            }
        end
    end

    -- Decimal digits

    if char == '.' then
        value = value .. char
        self:skip()

        -- Loop till the character is not a valid digit.
        while true do
            char = self:peek()

            if not isDecimalDigit(char) then
                break
            end

            value = value .. char
            self:skip()
        end
    end

    -- Exponent part.

    if char == 'e' or char == 'E' then
        value = value .. char
        self:skip()

        char = self:peek()

        if char == '+' or char == '-' then
            value = value .. char
            self:skip()
        end

        char = self:peek()
        if not isDecimalDigit(char) then -- illegal
            return nil
        end

        value = value .. char
        self:skip()

        -- Loop till the character is not a valid digit.
        while true do
            char = self:peek()

            if not isDecimalDigit(char) then
                break
            end

            value = value .. char
            self:skip()
        end

    end

    return {
        type = TokenType.NumericLiteral,
        value = value,
        base = base,
        isMalformed = false
    }
end

--[[
- Produce the next raw token or return 'nil' if no tokens can be matched.
- This method skips over all space characters.
]]
Lexer.proto.next = function(self)
    local token

    -- Move to the next non-whitespace character.
    while isWhitespaceCharacter(self:peek()) do
        self:skip()
    end

    -- Methods that work with multi-line structures and move the
    -- character pointer.

    token = nil
        or self:scanComments()
        or self:scanStringLiteral()

    if token then
        return token
    end

    -- Methods that don't move the character pointer.

    local token = nil
        or self:scanPunctuator()
        or self:scanKeyword()
        or self:scanIdentifier()
        or self:scanNumericLiteral()

    if token then
        return token
    end

    -- No token could be matched, give up.

    return nil
end

--[[
- Switch to the next line and reset all char pointers.
]]
Lexer.proto.nextLine = function(self)

    if self.lineNr >= #self.lines then
        return false
    end

    self.line = self.lines[self.lineNr + 1]
    self.lineNr = self.lineNr + 1
    self.charNr = 1

    -- TODO: Warnings..?

    return true
end

--[[
- Produce the next token. This function is called by advance() to get
- the next token.
]]
Lexer.proto.token = function(self)

    -- Keep returning `nil` when we passed EOF
    if self.exhausted then
        return nil
    end

    while true do

        -- End of line? Move to the next line.
        if self.charNr > #self.line then
            local startLineNr = self.lineNr
            local startCharNr = self.charNr

            if self:nextLine() then
                return {
                    type = TokenType.EndOfLine,
                    value = '<eol>',
                    line = startLineNr,
                    char = startCharNr
                }
            end

            self.exhausted = true
            return {
                type = TokenType.EndOfFile,
                value = '<eof>',
                line = self.lineNr,
                char = self.charNr
            }
        end

        local token = self:next()

        -- No token? Something may have gone wrong...
        if token == nil then

            if self.charNr <= #self.line then
                -- Unexpected character
                self:trigger('error', {
                    code = 'E024',
                    line = self.lineNr,
                    char = self.charNr,
                    data = {
                        self:peek()
                    }
                })

                -- Skip to EOL
                self:skipToEOL()
            end

            continue
        end

        --
        -- Trigger token event

        -- TODO

        if token.type == TokenType.Comment then
            self:trigger('Comment', token)
        end

        return token
    end

end

-- export
_G.Lexer = Lexer
