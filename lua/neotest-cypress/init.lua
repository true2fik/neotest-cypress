local lib = require("neotest.lib")
local async = require("neotest.async")

---@type neotest.Adapter
local adapter = { name = "neotest-cypress" }

adapter.root = function(dir)
  return lib.files.match_root_pattern("package.json")(dir)
end

adapter.filter_dir = function(name)
  return name ~= "node_modules"
end

adapter.is_test_file = function(file_path)
  if file_path == nil then
    return false
  end

  if file_path ~= nil and string.match(file_path, "%.cy%.ts$") then
    return true
  end
  return false
end

-- TODO: Use json reporter instead of junit
-- TODO: Handle multiple xml files using `suiteName`
adapter.build_spec = function(args)
  local position = args.tree:data()
  local junit_path = async.fn.tempname() .. ".junit.xml"
  vim.print(junit_path)
  local root = adapter.root(position.path)

  local command = {
    "npx", "cypress", "run", "-r", "junit", "-o", "mochaFile=" .. junit_path
  }

  if position.path ~= root then
    table.insert(command, "--spec")
    if position.type == "dir" then
      table.insert(command, position.path .. "/**/*")
    else
      table.insert(command, position.path)
    end
  end

  vim.print(command)
  return {
    command = command,
    context = {
      junit_path = junit_path,
    },
  }
end

---comment
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table
adapter.results = function(spec, result, tree)
  local results = {}

  -- TODO: multiple junit xml files
  local ok, data = pcall(lib.files.read, spec.context.junit_path)
  if ok then
    local root = lib.xml.parse(data)

    local testsuites
    if root.testsuites.testsuite == nil then
      testsuites = {}
    elseif #root.testsuites.testsuite == 0 then
      testsuites = { root.testsuites.testsuite }
    else
      testsuites = root.testsuites.testsuite
    end
    for _, testsuite in pairs(testsuites) do
      local testsuite_id
      if testsuite._attr.file ~= nil then
        testsuite_id = testsuite._attr.file
      else
        testsuite_id = testsuite._attr.name
      end
      if testsuite._attr.failures == "0" then
        results[testsuite_id] = {
          status = "passed",
        }
      else
        results[testsuite_id] = {
          status = "failed",
        }
      end
      local testcases
      if testsuite.testcase == nil then
        testcases = {}
      elseif #testsuite.testcase == 0 then
        testcases = { testsuite.testcase }
      else
        testcases = testsuite.testcase
      end
      for _, testcase in pairs(testcases) do
        if testcase.failure then
          local output = testcase.failure[1]

          results[testcase._attr.name] = {
            status = "failed",
            short = output,
          }
        else
          results[testcase._attr.name] = {
            status = "passed",
          }
        end
      end
    end
  end

  print(vim.inspect(results))
  return results
end

adapter.discover_positions = function(file_path)
  local query = [[
    ; -- Namespaces --
    ; Matches: `describe('context', () => {})`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe('context', function() {})`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition
    ; Matches: `describe.only('context', () => {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe.only('context', function() {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition
    ; Matches: `describe.each(['data'])('context', () => {})`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
        )
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe.each(['data'])('context', function() {})`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "describe" "context" "suite")
        )
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition

    ; -- Tests --
    ; Matches: `test('test') / it('test')`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "it" "test" "specify")
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `test.only('test') / it.only('test')`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "it" "test" "specify")
      )
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `test.each(['data'])('test') / it.each(['data'])('test')`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "it" "test" "specify")
          property: (property_identifier) @each_property (#eq? @each_property "each")
        )
      )
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
  ]]

  local positions = lib.treesitter.parse_positions(file_path, query, {
    require_namespaces = false,
    nested_tests = true,
    position_id = function(position, namespaces)
      if position.type == "namespace" then
        return position.name
      else
        return table.concat(
          vim.tbl_flatten({
            vim.tbl_map(function(pos)
              return pos.name
            end, namespaces),
            position.name,
          }),
          " "
        )
      end
    end,
  })

  return positions
end

return adapter
