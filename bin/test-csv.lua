--
--         FILE:  test-csv.lua
--       AUTHOR:  LeeoNix
--  DESCRIPTION:
--        NOTES:  ---
--

local csv = require 'csv'

function test()
    local t, err = csv.open(arg[1] or '_list.csv')
    if not t then
        print(err)
    end -- end if
    print('--------------------------------------------------------------------------------')
    for i, name, start, to, title in t:lines() do
        print(table.concat({i, name, start, to, title}, ','))
--        print(i, name, start, to, title)
    end -- end for
    print('--------------------------------------------------------------------------------')
    for i, v in ipairs(t) do
        print(i .. ',' .. table.concat(v, ','))
    end -- end for
    print('--------------------------------------------------------------------------------')
    t:print()
    print('--------------------------------------------------------------------------------')
    print(t)
    print('--------------------------------------------------------------------------------')
    t:write('_test.csv')
end -- end function

test()
