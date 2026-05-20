----------------------------------------------------------------
--- Copyright (c) 2006-2013 Fabien Fleutot and others.
---
--- All rights reserved.
---
--- This program and the accompanying materials are made available
--- under the terms of the Eclipse Public License v1.0 which
--- accompanies this distribution, and is available at
--- http://www.eclipse.org/legal/epl-v10.html
---
--- This program and the accompanying materials are also made available
--- under the terms of the MIT public license which accompanies this
--- distribution, and is available at http://www.lua.org/license.html
---
--- Contributors:
---     Fabien Fleutot - API and implementation
---
----------------------------------------------------------------

--- @class M
--- @field _acc table
--- @field current_indent integer
--- @field indent_step string
--- @field _line_len integer
--- @field _lines integer
--- @field comment_ids table
--- @field comment_lines table<integer, boolean>
--- @field wrap integer
local M = {}
M.__index = M

local pp = require("metalua.pprint")
require("stringutils.string")


----------------------------------------------------------------
--- Instantiate a new AST->source synthetizer
--- @param seen_comments integer[]?
--- @param w integer?
--- @return M
----------------------------------------------------------------
function M.new(seen_comments, w)
  local self = {
    -- Accumulates pieces of source as strings
    _acc = {},
    -- Current level of line indentation
    current_indent = 0,
    -- Indentation symbol, normally spaces or '\t'
    indent_step = "  ",
    -- Comments index accumulator
    comment_ids = seen_comments or {},
    comment_lines = {},
    -- Number of characters since last linebreak
    _line_len = 0,
    -- Number of linebreaks
    _lines = 0,
    -- wrap length
    wrap = w or 80,
    -- Last source line number emitted (used to detect blank-line gaps)
    _last_line = 0
  }
  return setmetatable(self, M)
end

----------------------------------------------------------------
--- Run a synthetizer on the `ast' arg and return the source as
--- a string.
--- Can also be used as a static method `M.run (ast)';
--- in this case a temporary Metizer is instantiated on the fly.
--- @param seen_comments integer[]?
--- @param w integer?
--- @return string
--- @return integer[]
----------------------------------------------------------------
function M:run(ast, seen_comments, w)
  if not ast then
    self, ast = M.new(seen_comments, w), self
  end
  self._acc = {}
  self:node(ast)
  return self:render()
end

--- @return string
--- @return integer[]
function M:render()
  return table.concat(self._acc), self.comment_ids
end

----------------------------------------------------------------
--- Spin up another instance and render the source for the
--- passed node
--- @param node token
--- @return string
----------------------------------------------------------------
function M:prerender(node)
  local comments = {}
  for k, v in pairs(self.comment_ids) do
    comments[k] = v
  end
  local w = self.wrap
  local renderer = M.new(comments, w)
  renderer:node(node)
  local rendered, _ = renderer:render()

  return rendered
end

----------------------------------------------------------------
--- Accumulate a piece of source file in the synthetizer.
--- @param x string
----------------------------------------------------------------
function M:acc(x)
  if x then
    local clen = self._line_len
    local l = string.ulen(x)
    local lines = string.lines(x)
    local n_l = #lines
    if l + clen > self.wrap
        --- if the string has multiple lines,
        --- handle it elsewhere
        and n_l < 2
        --- don't create a leading empty line
        --- for an overlong token
        and clen > 0
    then
      --- The formatter already emits a newline plus
      --- continuation indent here; keep separator spacing from
      --- adding a fifth visual indent column.
      local wrapped_x = x:gsub("^%s+", "")
      local ind = self.indent_step:rep(self.current_indent + 2)
      self:acc("\n" .. ind)
      self._line_len = #ind
      table.insert(self._acc, wrapped_x)
    else
      self._line_len = clen + l
      table.insert(self._acc, x)
    end
  end
end

----------------------------------------------------------------
--- Check if a piece of source can fit within the width limit
--- @param s string
----------------------------------------------------------------
function M:fits(s)
  if type(s) == 'string' then
    local clen = self._line_len
    local l = string.ulen(s)
    local lines = string.lines(s)
    local n_l = #lines
    if n_l == 1 then return l + clen < self.wrap end
    return true --- TODO
  end
end

----------------------------------------------------------------
--- Accumulate an indented newline.
----------------------------------------------------------------
function M:nl()
  local ind = self.indent_step:rep(self.current_indent)
  self:acc("\n" .. ind)
  self._line_len = string.len(ind)
  self._lines = self._lines + 1
  self._last_line = self._last_line + 1
end

----------------------------------------------------------------
--- Increase indentation and accumulate a new line.
----------------------------------------------------------------
function M:nlindent()
  self.current_indent = self.current_indent + 1
  self:nl()
end

----------------------------------------------------------------
--- Decrease indentation and accumulate a new line.
----------------------------------------------------------------
function M:nldedent()
  self.current_indent = self.current_indent - 1
  self:nl()
end

----------------------------------------------------------------
--- Insert a new line indented differently. Default is one deeper.
--- @param extra integer?
----------------------------------------------------------------
function M:nltempindent(extra)
  local add = extra or 1
  local depth = self.current_indent
  self.current_indent = depth + add
  self:nl()
  self.current_indent = depth
end

----------------------------------------------------------------
--- Keywords, which are illegal as identifiers.
----------------------------------------------------------------
local keywords_list = {
  "and",
  "break",
  "do",
  "else",
  "elseif",
  "end",
  "false",
  "for",
  "function",
  "if",
  "in",
  "local",
  "nil",
  "not",
  "or",
  "repeat",
  "return",
  "then",
  "true",
  "until",
  "while",
}
local keywords = {}
for _, kw in pairs(keywords_list) do
  keywords[kw] = true
end

----------------------------------------------------------------
--- Return true iff string `id' is a legal identifier name.
----------------------------------------------------------------
local function is_ident(id)
  -- HACK:
  if type(id) ~= "string" then
    return false
  end
  return
      string["match"](id, "^[%a_][%w_]*$") and not keywords[id]
end

----------------------------------------------------------------
--- Return true iff ast represents a legal function name for
--- syntax sugar ``function foo.bar.gnat() ... end'':
--- a series of nested string indexes, with an identifier as
--- the innermost node.
--- @param ast table
--- @return boolean
----------------------------------------------------------------
local function is_idx_stack(ast)
  local tag = ast.tag
  if tag == "Index" then
    if ast[2] then
      return ast[2].tag == "Id" or ast[2].tag == "String"
    end
    return is_idx_stack(ast[1])
  elseif tag == "Id" then
    return true
  else
    return false
  end
end

----------------------------------------------------------------
--- Returns the length of a call/index chain
--- @param ast table
--- @param depth integer?
--- @return integer
----------------------------------------------------------------
local function is_call_chain(ast, depth)
  local d = depth or 0
  local tag = ast.tag
  if tag == "Index" or tag == "Invoke" then
    return is_call_chain(ast[1], d + 1)
  elseif tag == "Id" then
    return d + 1
  else
    return d
  end
end

----------------------------------------------------------------
--- Operator precedences, in increasing order.
--- This is not directly used, it's used to generate op_prec below.
----------------------------------------------------------------
local op_preprec = {
  { "or",    "and" },
  { "lt",    "le",    "eq",  "ne" },
  { "concat" },
  { "add",   "sub" },
  { "mul",   "div",   "mod" },
  { "unm",   "unary", "not", "len" }, ---TODO:
  { "pow" },
  { "index" },
}

----------------------------------------------------------------
--- operator --> precedence table, generated from op_preprec.
----------------------------------------------------------------
local op_prec = {}

for prec, ops in ipairs(op_preprec) do
  for _, op in ipairs(ops) do
    op_prec[op] = prec
  end
end

----------------------------------------------------------------
--- operator --> source representation.
----------------------------------------------------------------
local op_symbol = {
  add = " + ",
  sub = " - ",
  mul = " * ",
  div = " / ",
  mod = " % ",
  pow = " ^ ",
  concat = " .. ",
  eq = " == ",
  ne = " ~= ",
  lt = " < ",
  le = " <= ",
  ["and"] = " and ",
  ["or"] = " or ",
  ["not"] = "not ",
  len = "#",
  unm = "-",
}

----------------------------------------------------------------
--- boolean operators that tie compound conditions together
----------------------------------------------------------------
local op_cond = { ["and"] = true, ["or"] = true }
----------------------------------------------------------------
--- right-binding associative operators
----------------------------------------------------------------
local op_infixr_assoc = { concat = true }
----------------------------------------------------------------
--- commutative operators
----------------------------------------------------------------
local op_comm = {
  add = true,
  mul = true,
  ["and"] = true,
  ["or"] = true,
}

--- @alias CommentPos 'first'|'last'
----------------------------------------------------------------
--- Extract comments from AST
--- @param node token
--- @return table
----------------------------------------------------------------
function M:extract_comments(node)
  if not node.lineinfo then return {} end
  local lfi = node.lineinfo.first
  local lla = node.lineinfo.last
  local comments = {}

  --- @param c table
  --- @param pos CommentPos
  local function add_comment(c, pos)
    local idf = c.lineinfo.first.id
    local idl = c.lineinfo.last.id
    local line = c.lineinfo.first.line
    --- the same comment might get picked up both as preceding
    --- the next expression and succeeding the previous one;
    --- chunk and statement nodes may also reference it with
    --- different lexeme ids.
    local present = self.comment_ids[idf] or self.comment_ids[idl]
        or self.comment_lines[line]
    if not present then
      local comment_text       = c[1]
      --- [[]] comments get parsed into two lexemes
      --- (the second is empty)
      local has_next           = c[2]
      local cfi                = c.lineinfo.first
      local cla                = c.lineinfo.last
      local cfirst             = { l = cfi.line, c = cfi.column }
      local clast              = { l = cla.line, c = cla.column }
      --- if the number of lines in the text is less than the
      --- apparent positions, add the newline back
      local n_l                = #(string.lines(comment_text))
      local l_d                = cla.line - cfi.line
      local newline            = (n_l ~= 0 and n_l == l_d)
      local li                 = {
        idf = idf,
        idl = idl,
        first = cfirst,
        last = clast,
        text = comment_text,
        multiline = has_next,
        position = pos,
        prepend_newline = newline
      }
      self.comment_ids[idf]    = true
      self.comment_ids[idl]    = true
      self.comment_lines[line] = true
      table.insert(comments, li)
    end
  end
  if lfi.comments then
    for _, c in ipairs(lfi.comments) do
      add_comment(c, 'first')
    end
  end
  if lla.comments then
    for _, c in ipairs(lla.comments) do
      add_comment(c, 'last')
    end
  end

  return comments
end

----------------------------------------------------------------
--- Accumulate the source representation of AST `node' in
--- the synthetizer. Most of the work is done by delegating to
--- the method having the name of the AST tag.
--- If something can't be converted to normal sources, it's
--- instead dumped as a `-{ ... }' splice in the source accumulator.
--- @param node token
----------------------------------------------------------------
function M:node(node)
  assert(self ~= M and self._acc)
  if node == nil then
    self:acc("<<error>>")
    return
  end
  local comments = self:extract_comments(node)
  --- @param pos 'first'|'last'
  local function show_comments(pos)
    --- to avoid double dipping, only show corresponding
    for _, co in pairs(comments) do
      if co.position == pos then
        --- comes _after_ a previous expression
        if co.position == 'last' then self:nl() end
        --- if the comment was preceded by a blank line in the
        --- original source, emit exactly one blank line before it
        if co.position == 'first' and co.first.l - self._last_line >= 2 then
          self:nl()
        end
        --- preserve existing newlines
        local lines = string.lines(co.text)
        if co.multiline then
          --- multliine comment (--[[]])
          if co.prepend_newline then
            table.insert(lines, 1, '')
          end
          local l1 = lines[1] or ''
          if #lines == 1 then
            lines[1] = '--[[' .. l1 .. ']]'
          else
            local llast = lines[#lines] or ''
            lines[1] = '--[[' .. l1
            lines[#lines] = llast .. ']]'
          end
          local wrapped = string.wrap_array(lines, self.wrap)
          for i, l in ipairs(wrapped) do
            self:acc(l)
            if i ~= #wrapped then self:nl() end
          end
        else
          local ls = co.first.l
          local le = co.last.l
          local wrapped =
              string.wrap_array(lines, self.wrap - 3)
          if ls == le then
            --- (originally) single line comment
            if co.text == '' then
              self:acc('--')
            else
              for i, l in ipairs(wrapped) do
                local first = string.sub(l, 1, 1)
                local pre = '--'
                --- add a space if not present already
                --- do not break up '---'-style comments
                if i == 1 and first == ' ' or first == '-'
                --- in this case, only for the first line
                then
                else
                  pre = pre .. ' '
                end
                self:acc(pre .. l)
                if i ~= #wrapped then self:nl() end
              end
            end
          else
            --- multiple single line comments
            for i, l in ipairs(wrapped) do
              local first = string.sub(l, 1, 1)
              local pre = '--'
              --- add a space if not present already
              --- do not break up '---'-style comments
              if first == ' ' or first == '-'
              then
              else
                pre = pre .. ' '
              end
              self:acc(pre .. l)
              if i ~= #wrapped then self:nl() end
            end
          end
        end
        --- comes _before_ the next expression
        if co.position == 'first' then self:nl() end
      end
    end
  end

  show_comments('first')
  --- advance _last_line to the node's own start line so that
  --- subsequent blank-line checks are relative to rendered output
  if node.lineinfo and node.lineinfo.first then
    local nl = node.lineinfo.first.line
    if nl and nl > self._last_line then
      self._last_line = nl
    end
  end
  if not node.tag then --- tagless block.
    self:list(node, self.nl)
  else
    local f = M[node.tag]
    if type(f) == "function" then   --- Delegate to tag method.
      f(self, node, unpack(node))
    elseif type(f) == "string" then --- tag string.
      self:acc(f)
    else
      --- No appropriate method, fall back to splice dumping.
      --- This cannot happen in a plain Lua AST.
      self:acc(" -{ ")
      self:acc(pp.tostring(node,
        { metalua_tag = 1, hide_hash = 1, line_max = 80 }))
      self:acc(" }")
    end
  end
  show_comments('last')
end

----------------------------------------------------------------
--- Convert every node in the AST list passed as 1st arg.
--- @param list table
--- @param sep string|function
--- Optional separator to be accumulated between each list
--- element, it can be a string or a synth method.
--- @param start integer?
--- Optional number (default == 1), indicating which is the
--- first element of list to be converted, so that we can skip
--- the begining of a list.
----------------------------------------------------------------
function M:list(list, sep, start)
  for i = start or 1, #list do
    self:node(list[i])
    if list[i + 1] then
      if not sep then
      elseif type(sep) == "function" then
        sep(self)
      elseif type(sep) == "string" then
        self:acc(sep)
      else
        error("Invalid list separator")
      end
    end
  end
end

----------------------------------------------------------------
--- M:list() with line wrapping
--- @param list table
--- @param sep string|function
--- @param start integer?
--- @param split 'single'|'all'?
----------------------------------------------------------------
function M:wrapped_list(list, sep, start, split)
  local function prerender_list()
    local s = ''
    for i = start or 1, #list do
      s = s .. self:prerender(list[i])
      if list[i + 1] then
        if not sep then
          --- TODO
          -- elseif type(sep) == "function" then
          --    sep(self)
        elseif type(sep) == "string" then
          s = s .. sep
        else
          error("Invalid list separator")
        end
      end
    end
    return s
  end
  local split_type = split or 'single'
  local pre = prerender_list()
  if self:fits(pre) then
    self:list(list, sep, start)
    return
  end
  if split_type == 'all' then
    self:nlindent()
    local newsep = function(self)
      if type(sep) == "string" then
        self:acc(string.normalize(sep))
      else
        sep(self)
      end
      self:nl()
    end
    self:list(list, newsep, start)
    self:nldedent()
  else
    self:list(list, sep, start)
    --- TODO
    -- local midpoint = math.ceil(#list / 2)
    -- local starter = {}
    -- for i = 1, midpoint do
    --    table.insert(starter, list[i])
    -- end
    -- print('m', midpoint)
    -- self:wrapped_list(starter, sep)
    -- self:nltempindent()
    -- self:wrapped_list(list, sep, midpoint + 1)
  end
end

----------------------------------------------------------------
---
--- Tag methods.
--- ------------
---
--- Specific AST node dumping methods, associated to their node
--- kinds by their name, which is the corresponding AST tag.
--- synth:node() is in charge of delegating a node's treatment
--- to the appropriate tag method.
---
--- Such tag methods are called with the AST node as 1st arg.
--- As a convenience, the n node's children are passed as
--- args #2 ... n+1.
---
--- There are several things that could be refactored into
--- common subroutines here: statement blocks dumping,
--- function dumping...
--- However, given their small size and linear execution
--- (they basically perform series of :acc(), :node(), :list(),
--- :nl*() calls), it seems more readable
--- to avoid multiplication of such tiny functions.
---
--- To make sense out of these, you need to know metalua's AST
--- syntax, as found in the reference manual or in
--- metalua/doc/ast.txt.
----------------------------------------------------------------

function M:Do(node)
  self:acc("do")
  self:nlindent()
  self:list(node, self.nl)
  self:nldedent()
  self:acc("end")
end

function M:Set(node)
  local lhs = node[1]
  local rhs = node[2]
  if
  --- LHS = { `Index{ lhs, `String{ method } } },
  ---       { `Index{ lhs[1][1], `String{ lhs[1][2][1] } } },
  --- RHS = { `Function{ { `Id "self", ... } ==
  ---                                     params, body } } }
  ---       { `Function{ { `Id "rhs[1][1][1][1]", ... } ==
  ---                                     params, body } } }
      lhs[1].tag == "Index"
      and rhs[1].tag == "Function"
      and rhs[1][1][1] and rhs[1][1][1][1] == "self"
      and is_idx_stack(lhs[1][1])
      and is_ident(lhs[1][2][1])
  then
    --- block 1
    --- `function foo:bar(...) ... end` ---
    local method = lhs[1][2][1]
    local params = rhs[1][1]
    local body = rhs[1][2]
    self:acc("function ")
    self:node(lhs[1][1])
    self:acc(":")
    self:acc(method)
    self:acc("(")
    self:wrapped_list(params, ", ", 2, 'all')
    self:acc(")")
    self:nlindent()
    self:list(body, self.nl)
    self:nldedent()
    self:acc("end")
  elseif rhs[1].tag == "Function"
      and is_idx_stack(lhs[1])
  then
    --- block 2
    --- `function foo(...) ... end` ---
    local params = rhs[1][1]
    local body = rhs[1][2]
    self:acc("function ")
    self:node(lhs[1])
    self:acc("(")
    self:wrapped_list(params, ", ", nil, 'all')
    self:acc(")")
    self:nlindent()
    self:node(body)
    self:nldedent()
    self:acc("end")
    --- metalua extensions
    --[[ elseif rhs[1].tag == "Id"
           and not is_ident(lhs[1][2][1])
       then
          --- block 3
          --- `foo, ... = ...` when foo is *not* a valid id.
          --- In that case, the spliced 1st variable must get parentheses,
          --- to be distinguished from a statement splice.
          --- This cannot happen in a plain Lua AST.
          self:list(lhs, ", ")
          self:acc(" = ")
          self:list(rhs, ", ")
       elseif node[3] then
          --- block 5
          --- `... = ...`, no syntax sugar, annotation ---
          local annot = node[3]
          local n = #lhs
          for i = 1, n do
             local ell, a = lhs[i], annot[i]
             self:node(ell)
             if a then
                self:acc ' #'
                self:node(a)
             end
             if i ~= n then self:acc ', ' end
          end
          self:acc " = "
          self:list(rhs, ", ")--]]
  else
    --- block 4
    --- `... = ...`, no syntax sugar ---
    self:wrapped_list(lhs, ", ")
    self:acc(" = ")
    self:wrapped_list(rhs, ", ")
  end
end

function M:While(_, cond, body)
  self:acc("while ")
  self:node(cond)
  self:acc(" do")
  self:nlindent()
  self:list(body, self.nl)
  self:nldedent()
  self:acc("end")
end

function M:Repeat(_, body, cond)
  self:acc("repeat")
  self:nlindent()
  self:list(body, self.nl)
  self:nldedent()
  self:acc("until ")
  self:node(cond)
end

function M:If(node)
  for i = 1, #node - 1, 2 do
    --- for each ``if/then'' and ``elseif/then'' pair --
    local cond, body = node[i], node[i + 1]
    self:acc(i == 1 and "if " or "elseif ")
    local lc = self._lines
    self:node(cond)
    local ml = self._lines > lc
    if ml then
      self:nl()
      self:acc("then")
    else
      self:acc(" then")
    end
    self:nlindent()
    self:list(body, self.nl)
    self:nldedent()
  end
  --- odd number of children --> last one is an `else' clause --
  if #node % 2 == 1 then
    self:acc("else")
    self:nlindent()
    self:list(node[#node], self.nl)
    self:nldedent()
  end
  self:acc("end")
end

function M:Fornum(node, var, first, last)
  local body = node[#node]
  self:acc("for ")
  self:node(var)
  self:acc(" = ")
  self:node(first)
  self:acc(", ")
  self:node(last)
  if #node == 5 then --- 5 children -->
    ---                              child #4 is a step increment.
    self:acc(", ")
    self:node(node[4])
  end
  self:acc(" do")
  self:nlindent()
  self:list(body, self.nl)
  self:nldedent()
  self:acc("end")
end

function M:Forin(_, vars, generators, body)
  self:acc("for ")
  self:list(vars, ", ")
  self:acc(" in ")
  self:list(generators, ", ")
  self:acc(" do")
  self:nlindent()
  self:list(body, self.nl)
  self:nldedent()
  self:acc("end")
end

function M:Local(node, lhs, rhs, annots)
  if next(lhs) then
    self:acc("local ")
    if annots then
      local n = #lhs
      for i = 1, n do
        self:node(lhs)
        local a = annots[i]
        if a then
          self:acc(" #")
          self:node(a)
        end
        if i ~= n then
          self:acc(", ")
        end
      end
    else
      self:wrapped_list(lhs, ", ")
    end
    if rhs[1] then
      self:acc(" = ")
      self:wrapped_list(rhs, ", ")
    end
  else
    --- Can't create a local statement with 0 variables in
    --- plain Lua
    self:acc(pp.tostring(node, "nohash"))
  end
end

function M:Localrec(_, lhs, rhs)
  --- ``local function name() ... end'' --
  self:acc("local function ")
  self:acc(lhs[1][1])
  self:acc("(")
  self:wrapped_list(rhs[1][1], ", ", nil, 'all')
  self:acc(")")
  self:nlindent()
  self:list(rhs[1][2], self.nl)
  self:nldedent()
  self:acc("end")
  --
  -- | _ ->
  --    -- Other localrec are unprintable ==> splice them --
  --        -- This cannot happen in a plain Lua AST. --
  --    self:acc "-{ "
  --    self:acc (table.tostring (node, 'nohash', 80))
  --    self:acc " }"
  -- end
end

function M:Call(node, f)
  self:node(f)
  self:acc("(")
  self:wrapped_list(node, ", ", 2, 'all') --- skip `f'.
  self:acc(")")
end

function M:Invoke(node, f, method)
  if node[1].tag == 'String' then
    self:acc("(")
    self:node(f)
    self:acc(")")
  else
    self:node(f)
  end
  self:acc(":")
  self:acc(method[1])
  self:acc("(")
  --- Skip args #1 and #2, object and method name.
  self:wrapped_list(node, ", ", 3, 'all')
  self:acc(")")
end

function M:Return(node)
  self:acc("return ")
  self:wrapped_list(node, ", ")
end

M.Break = "break"
M.Nil = "nil"
M.False = "false"
M.True = "true"
M.Dots = "..."

function M:Number(_, n)
  self:acc(tostring(n))
end

function M:String(_, str)
  local fl        = string.len('"" ..' .. self.indent_step)
  local wl        = self.wrap - fl
  local multiline = string.ulen(str) > wl
  local rendered  = ''
  --- format "%q" prints '\n' in an umpractical way IMO,
  --- so this is fixed with the :gsub( ) call.
  if multiline then
    --- split the raw text
    local split = string.lines(str) or {}
    --- add newline placeholders
    for i, v in ipairs(split) do
      if i ~= #split then
        split[i] = v .. '\\n'
      end
    end
    --- wrap
    local ls = string.wrap_array(split, wl)
    for i, v in ipairs(ls) do
      rendered = rendered .. "\n" .. self.indent_step
      rendered = rendered ..
          string.format("%q", v):gsub("\\\\", [[\]])
      if i ~= #ls then
        rendered = rendered .. ' ..'
      end
    end
  else
    rendered = string.format("%q", str):gsub("\\\n", [[\n]])
  end
  self:acc(rendered)
end

function M:Function(_, params, body, annots)
  self:acc("function(")
  if annots then
    local n = #params
    for i = 1, n do
      local p, a = params[i], annots[i]
      self:node(p)
      if annots then
        self:acc(" #")
        self:node(a)
      end
      if i ~= n then
        self:acc(", ")
      end
    end
  else
    self:wrapped_list(params, ", ", nil, 'all')
  end
  self:acc(")")
  self:nlindent()
  self:list(body, self.nl)
  self:nldedent()
  self:acc("end")
end

function M:Table(node)
  if not node[1] then
    self:acc("{ }")
  else
    self:acc("{")
    local newline =
        #node > 1 or
        (node[1].tag == "Pair" and node[1][2].tag == "Function")
    if newline then
      self:nlindent()
    else
      self:acc(" ")
    end
    for i, elem in ipairs(node) do
      if elem.tag == "Pair" then
        if elem[1].tag == "String" and is_ident(elem[1][1]) then
          --- `Pair{ `String{ key }, value }
          self:acc(elem[1][1])
          self:acc(" = ")
          self:node(elem[2])
        else
          --- `Pair{ key, value }
          self:acc("[")
          self:node(elem[1])
          self:acc("] = ")
          self:node(elem[2])
        end
      else
        self:node(elem)
      end
      if node[i + 1] then
        self:acc(",")
        self:nl()
      end
    end
    if newline then
      self:nldedent()
    else
      self:acc(" ")
    end
    self:acc("}")
  end
end

function M:Op(node, op, a, b)
  --- Transform ``not (a == b)'' into ``a ~= b''. --
  if op == "not" then
    if node[2][1] == "eq" then
      op, a, b = "ne", node[2][2], node[2][3]
    end
    if (node[2].tag == "Paren" and node[2][1][1] == "eq")
    then
      op, a, b = "ne", node[2][1][2], node[2][1][3]
    end
  end

  if b then --- binary operator.
    local left_paren, right_paren = false, false
    if a.tag == "Op"
        and op_prec[op] >= op_prec[a[1]]
        and not op_comm[a[1]]
    then
      left_paren = true
    end
    if b.tag == "Op"
        and op_prec[op] >= op_prec[b[1]]
        and not op_infixr_assoc[b[1]]
    then
      right_paren = true
    end

    self:acc(left_paren and "(" or '')
    self:node(a)
    self:acc(left_paren and ")" or '')

    if op_cond[op] then
      local pre = op_symbol[op] .. self:prerender(b)
      if not self:fits(pre)
          or (
            type(a[2]) == "table"
            and type(b[2]) == "table"
            and (a[2].lineinfo and b[2].lineinfo
              and a[2].lineinfo.first and b[2].lineinfo.first
              and a[2].lineinfo.first.line <
              b[2].lineinfo.first.line)
          )
      then
        self:nltempindent(2)
      end
    end
    self:acc(op_symbol[op])

    self:acc(right_paren and "(" or '')
    self:node(b)
    self:acc(right_paren and ")" or '')
  else --- unary operator.
    local paren = false
    if a.tag == "Op" then
      paren = op_prec[op] >= op_prec[a[1]]
    end
    if op == 'len' and is_call_chain(a) > 1 then
      paren = true
    end
    self:acc(op_symbol[op])
    self:acc(paren and "(" or '')
    self:node(a)
    self:acc(paren and ")" or '')
  end
end

function M:Paren(_, content)
  local pre = "(" .. self:prerender(content) .. ")"
  if not self:fits(pre) then
    self:nltempindent()
  end
  self:acc("(")
  self:node(content)
  self:acc(")")
end

function M:Index(_, table, key)
  local paren_table
  if table.tag == "Op"
      and op_prec[table[1][1]] < op_prec.index
  then
    paren_table = true
  else
    paren_table = false
  end

  self:acc(paren_table and "(" or "")
  self:node(table)
  self:acc(paren_table and ")" or "")

  if key.tag == 'String' and is_ident(key[1]) then
    --- ``table [key]''
    self:acc(".")
    self:acc(key[1])
  else
    --- ``table.key''
    self:acc("[")
    self:node(key)
    self:acc("]")
  end
end

function M:Id(node, name)
  if is_ident(name) then
    self:acc(name)
  else
    --- Unprintable identifier, fall back to splice repr.
    --- This cannot happen in a plain Lua AST.
    self:acc("-{`Id ")
    self:String(node, name)
    self:acc("}")
  end
end

-- M.TDyn    = '*'
-- M.TDynbar = '**'
-- M.TPass   = 'pass'
-- M.TField  = 'field'
-- M.TIdbar  = M.TId
-- M.TReturn = M.Return
--
--
-- function M:TId (node, name) self:acc(name) end
--
--
-- function M:TCatbar(node, te, tebar)
--     self:acc'('
--     self:node(te)
--     self:acc'|'
--     self:tebar(tebar)
--     self:acc')'
-- end
--
-- function M:TFunction(node, p, r)
--     self:tebar(p)
--     self:acc '->'
--     self:tebar(r)
-- end
--
-- function M:TTable (node, default, pairs)
--     self:acc '['
--     self:list (pairs, ', ')
--     if default.tag~='TField' then
--         self:acc '|'
--         self:node (default)
--     end
--     self:acc ']'
-- end
--
-- function M:TPair (node, k, v)
--     self:node (k)
--     self:acc '='
--     self:node (v)
-- end
--
-- function M:TIdbar (node, name)
--     self :acc (name)
-- end
--
-- function M:TCatbar (node, a, b)
--     self:node(a)
--     self:acc ' ++ '
--     self:node(b)
-- end
--
-- function M:tebar(node)
--     if node.tag then self:node(node) else
--         self:acc '('
--         self:list(node, ', ')
--         self:acc ')'
--     end
-- end
--
-- function M:TUnkbar(node, name)
--     self:acc '~~'
--     self:acc (name)
-- end
--
-- function M:TUnk(node, name)
--     self:acc '~'
--     self:acc (name)
-- end
--
-- for name, tag in pairs{ const='TConst', var='TVar', currently='TCurrently', just='TJust' } do
--     M[tag] = function(self, node, te)
--         self:acc (name..' ')
--         self:node(te)
--     end
-- end

-- print(M.run(+{stat: local function add(a, b)
--    local c = a + b; return add(a,c) end}))

M.oneshot = function(x, ...)
  local a2s = M.new(...)
  return a2s:run(x)
end
return M
