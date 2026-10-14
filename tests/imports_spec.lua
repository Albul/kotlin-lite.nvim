local imports = require("kotlin-lite.imports")

describe("file header", function()
    local ctx = imports.parse({
        "// header comment",
        "@file:JvmName(\"X\")",
        "package a.b",
        "",
        "import x.y.Foo",
        "import x.y.Outer.Inner",
        "import x.y.bar as baz",
        "import w.z.*",
        "",
        "class Local",
        "import not.a.Header", -- after the first declaration: ignored
    })

    describe("parse", function()
        it("package", function()
            assert.are.equal("a.b", ctx.package)
        end)
        it("explicit imports", function()
            assert.are.equal("x.y", ctx.explicit.Foo)
            assert.are.equal("x.y.Outer", ctx.explicit.Inner)
        end)
        it("alias", function()
            assert.are.equal("bar", ctx.aliases.baz.name)
            assert.are.equal("x.y", ctx.aliases.baz.qualifier)
        end)
        it("wildcard", function()
            assert.are.same({ "w.z" }, ctx.wildcards)
        end)
        it("stops at the first declaration", function()
            assert.is_nil(ctx.explicit.Header)
        end)
    end)

    describe("rank (explicit > same package > star > default)", function()
        local cases = {
            { "explicit import", "Foo", "x.y", 1 },
            { "explicit shadows same package", "Foo", "a.b", imports.NONE },
            { "nested explicit import", "Inner", "x.y", 1 },
            { "same package", "Thing", "a.b", 2 },
            { "star import", "Thing", "w.z", 3 },
            { "default import", "Thing", "kotlin.collections", 4 },
            { "unrelated", "Thing", "q.r", imports.NONE },
            { "no package", "Thing", nil, imports.NONE },
        }
        for _, c in ipairs(cases) do
            local name, word, pkg, want = c[1], c[2], c[3], c[4]
            it(name, function()
                assert.are.equal(want, imports.rank(ctx, word, pkg))
            end)
        end
    end)
end)
