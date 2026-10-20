# kotlin-lite.nvim

Kotlin navigation for Neovim without a language server. `gd`, find usages,
rename, go to implementation, auto-import and the rest work by searching the
code with `ripgrep` and reading it the way the compiler would: the file's
imports, the scope you're in, the type of the receiver before the dot.

It starts instantly, works on big Kotlin / Android / KMP projects, and goes
into library sources too: the sources of your Gradle dependencies, the
Android SDK and the JDK.

It isn't a compiler, though. When a name could mean several things and the
plugin can't tell which, it shows you the candidates instead of guessing. See
[Limitations](#limitations).

## Quick start

You need Neovim 0.10+ and [`ripgrep`](https://github.com/BurntSushi/ripgrep)
(`rg`), `unzip` and `find` on your `PATH`. With
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "olekdia/kotlin-lite.nvim",
    event = "VeryLazy", -- or ft = { "kotlin" } if you don't need the <leader>k project maps before a .kt file
    opts = {},
}
```

That's it, no configuration needed. Open a Kotlin file and press `gd`.

The project root is the directory Neovim was started in. In a Gradle project
the plugin fetches your dependencies' sources in the background the first
time, so `gd` can go into libraries (see [Library sources](#library-sources)).

## Keys at a glance

All of these work in Kotlin buffers. Each key is described in more detail
[further down](#in-detail).

**Navigate**

| Key | What it does |
| --- | --- |
| `gd` | Go to definition |
| `grt` | Go to the type of what's under the cursor |
| `gri` | Go to implementations / subtypes |
| `<leader>ku` | Go to super: supertypes, or the member this one overrides |
| `<C-]>`, `:tag`, … | Vim's tag commands, resolved like `gd` |
| `<C-t>` | Back, jump by jump (every jump goes on the tag stack) |

**Look up**

| Key | What it does |
| --- | --- |
| `K` | Declaration and KDoc in a float |
| `gK`, `<C-s>` in insert mode | Signature of the call you're typing, current argument highlighted |
| `gu`, `grr` | Find usages (quickfix) |
| `]r` / `[r` | Next / previous occurrence of the symbol in this file |
| `<leader>kh` | Incoming calls: usages, named after the function they're in |

**Change code**

| Key | What it does |
| --- | --- |
| `<leader>cr` | Rename, with a preview of every change |
| `<leader>cR` | Rename the file, and the class it's named after |
| `<leader>ki` | Add the import for the name under the cursor |
| `<leader>co` | Organize imports |
| `<leader>cf` | Format the buffer (ktlint by default) |

**Find your way around**

| Key | What it does |
| --- | --- |
| `<leader>cs` | Outline of this file |
| `<leader>cS` | Search classes and functions in the project |
| `<leader><leader>` | Find files |
| `<leader>ka` | Switch between `Foo.kt` and `FooTest.kt` |
| `<leader>ke` | Reveal the file in the snacks.nvim explorer |
| `<leader>kc` | Copy the fully qualified name |

**Run**

| Key | What it does |
| --- | --- |
| `<leader>kr` / `<leader>kR` | Run this file / the project |
| `<leader>kt` / `<leader>kT` | Test this file / the project |
| `<leader>ks` | Fetch the sources of all dependencies |

Every key can be changed or turned off (see [Configuration](#configuration)).
If your fingers know IntelliJ, there's an [IntelliJ keymap set](#intellij-keymaps)
too.

## In detail

### Go to definition (`gd`)

`gd` looks in the current buffer first, by lexical scope: the innermost block
wins, a local counts only after it's declared, comments and strings are
ignored. Then it searches the project and the extracted library sources, and
ranks what it finds the way the compiler would from the file's header:
explicit import, then same package, then `*` import, then the default
`kotlin.*` imports. `as` aliases are followed. If there's one best match, it
jumps straight there.

**It follows the receiver.** For `x.member` it works out the type of `x`:

- declared, constructed, or from `by lazy { T() }` / `remember { T() }`;
- when several declarations compete, it looks the type up through chains like
  `a.b.c` or `f().x` that start at a local, `this`, an imported name, a type, a
  constructor call or a cast `(x as T)`;
- a numeric literal has its type, so `3.days` finds the `Int.days` that its
  import brings in.

Such a lookup gets 150 ms. If it takes longer, you get the candidates as they
are. A type it found is remembered for the next `gd` until a buffer changes.

**It also handles:**

- `Type.member`, including companion members and enum entries;
- `this.` and `super.`, members inherited from supertypes, members reached
  through a `typealias`;
- extensions, by their receiver type;
- code inside `x.apply { }`, `with(x) { }` and DSL lambdas (`T.() -> Unit` of
  the called function);
- overloads, narrowed by the call's arguments;
- a named argument `f(name = …)`: jumps to that parameter;
- `it`: jumps to the `{` of its lambda;
- Java methods, fields and enum entries.

An unqualified name prefers members of the enclosing classes and never picks
a member of an unrelated class.

**On a declaration**, `override` goes to the overridden member and `actual`
goes to its `expect`. Anything else stays put. In library sources, the
`expect` or `actual` this file compiles against is picked: common code gets
the `expect`, JVM / Android code the JVM `actual`.

**On an `import` line**, it resolves the full path (nested classes and `as`
aliases too) and jumps without a picker.

**Several matches** open a picker with a preview. Each row shows
`expect`/`actual`, the signature, the source set, the module or
`artifact version`, and `file:line`. Older versions of the same library are
hidden.

**Every jump goes on the tag stack**, so `<C-t>` and `:tags` walk back the way
they do with an LSP.

**Beyond Kotlin code:**

- `R.string.x` / `Res.drawable.x` (Android and Compose resources) jump into
  `res/` or `composeResources/`: to the `<string name="x">` of the default
  `values/`, to the file of a `drawable` / `layout` / `mipmap` / …, to the
  `@+id/x` of an `R.id.x`;
- `BuildConfig.X` jumps to its `buildConfigField`. One per build type or
  flavor means a picker. `VERSION_NAME`, `VERSION_CODE` and `APPLICATION_ID`
  go to the Android property;
- in build scripts, `libs.x.y`, `libs.plugins.x`, `libs.versions.x` and
  `libs.bundles.x` jump to the entry in `libs.versions.toml`, from any segment
  of the chain. `projects.x.y` goes to the module's build file.

### Type, super, implementations

**`grt`** goes to the type of what the cursor is on. The type can be declared,
constructed, a literal, or the return type of the call or property it's
initialised from. `List<Foo>` goes to `List`, a `typealias` to the type it
stands for. On a class name, it goes to the class. The type is resolved in the
header of the file that declares it.

**`<leader>ku`** (IntelliJ `Ctrl+U`) goes to the supertypes of a class, or to
the member that the member under the cursor overrides.

**`gri`** starts from whatever `gd` resolves to: receiver types, lambda
receivers and named arguments included. On a declaration, it starts from that
declaration, an `override` too.

- **On a type:** its subtypes, transitively. That includes anonymous
  `object : T`, subtypes declared through its `typealias`es, subclasses
  written in Java (`extends` / `implements`), in libraries and in the Android
  SDK / JDK, and where it's registered in Koin (`single<T> { }`,
  `factory<T>`, `bind<T>()`, `bind T::class`).
- **On a `fun` / `val` / `var`:** the `override`s inside those subtypes.
- **On an `expect` class or member:** its `actual`s.

A supertype reference is checked against each file's package and imports, so
a same-named type from another package doesn't count. If the receiver is
unknown, `override`s count as implementations and you're offered only the
declarations they implement. One result means a jump, several mean a picker.

### Hover and signatures

**`K`** shows the declaration and its KDoc for whatever `gd` resolves to. For
locals and parameters it reads the buffer, unsaved edits included. If there
are several candidates, it shows the best-ranked one. On `it`, it shows the
lambda's receiver for `let` / `also`, or the element type for `forEach` /
`map` / ….

It also works on:

- `R.string.x` / `Res.string.x`: the value in every `values-*`;
- `BuildConfig.X`: its definition per build type;
- `libs.x`: the catalog entry and its `version.ref`.

**`gK`** (or `<C-s>` in insert mode) shows the signature of the call you're
in, picking the overload that takes the call's arguments. The current
argument's parameter is highlighted, positional or named.

**Tags.** `<C-]>`, `<C-w>]`, `g]`, `:tag`, `:ptag` and `<C-w>}` resolve like
`gd` through `'tagfunc'`, the same way Neovim does it for LSP buffers. That
gives you jump, open in a split, list all candidates, jump by name, and
preview without leaving the file.

### Usages, occurrences, incoming calls

**`gu`** finds the usages of what the cursor resolves to and puts them in the
quickfix list. Where it looks depends on the declaration:

- a local or a parameter: its scope, plus named arguments at calls of its
  function;
- `private`: its file;
- `internal`: its module;
- anything else: the whole project.

An occurrence is dropped when:

- a local shadows the name;
- the file doesn't see a top-level declaration (by package and imports);
- the receiver's type is known and is outside the member's class and its
  subtypes;
- it's in a comment or a string.

For `it`, the search stays in its lambda.

It also understands non-Kotlin references:

- a resource `R.string.x`: every `R.string.x` in code and every `@string/x` in
  Android XML;
- `BuildConfig.X`, `libs.x` and `projects.x`: where they're used.

For a name it can't resolve, it lists every mention outside comments.

**`]r` / `[r`** move to the next / previous occurrence of the symbol under the
cursor. These are the same occurrences highlighted on `CursorHold`, by the same
scope rules. They take a count and wrap around per `'wrapscan'`.

**`<leader>kh`** (IntelliJ `Ctrl+Alt+H`) shows incoming calls: the usages `gu`
finds, each named after the function or property it's in (`Counter.bump`,
`Counter.Companion.zero`, `main`). Imports and the declaration itself are left
out.

### Rename (`<leader>cr`)

A local or a parameter is renamed in the buffer straight away. Anything else
opens a preview first: every occurrence the rename would change, grouped by
file, each with its line and the new name shown inline.

```
Rename balance → funds   5 of 7 selected
<Space> toggle (a line, a file, a visual range)  a all / none  p context  <CR> apply  q cancel

usages/a/Account.kt
  [x]      4  var balance = 0
  [x]      8  balance += amount

usages/b/Bank.kt
  [x]      7  a.balance = 1
  [ ]     13  ledger().balance = 5        ← Ledger
  [ ]?    14  unknownThing().balance = 6
```

- Occurrences the plugin is sure about are checked.
- Where the receiver's type isn't known yet, the line is marked `[?]` and
  starts unchecked. While the preview is open, those types are looked up one
  by one, the way `gd` does it. A receiver of the declaration's type gets
  checked. One of another type stays unchecked and shows that type.
  Lines you toggled yourself are left alone.
- `<Space>` toggles a line, a whole file (on the file name) or a visual range.
  `a` toggles everything. `p` shows a few lines of context. `q` cancels.
- `<CR>` applies the checked lines and saves the files. A file that already
  had unsaved changes gets the edit but isn't written, so your own changes
  stay yours to save. An occurrence that changed since the preview opened is
  skipped, and you're told how many.

A name that doesn't resolve shows every mention of the word, comments and
strings included. Declarations in libraries can't be renamed.

### Rename file (`<leader>cR`)

This renames the file. If the file has a top-level `class`, `interface`,
`object` or `fun` with the same name, that gets renamed too, through the
same preview as `<leader>cr`. In a `.java` file it's a `class`, `interface`,
`enum`, `record` or `@interface`, constructors included. Java needs this:
a public class has to match its file name.

The declaration is resolved from where it's declared, so its usages are found
wherever it's visible, other modules included. Press `q` in the preview to
rename only the file.

If the file is open with unsaved changes, it moves with those changes and
nothing gets written for you.

### Imports

**`<leader>ki`** adds the import for the name under the cursor. It looks in the
project, the extracted library sources and the public API of the Android SDK
or the JDK. It can import:

- classes, nested ones too (`Outer.Nested`);
- top-level `fun`, `val` and `const val`, extensions included (after a `.`,
  only extensions are offered);
- members of `object`s and companions;
- enum entries;
- Java `static` members.

It skips private, class-member and local declarations, and names the file
already sees (default `kotlin.*` imports, the same package, `*` imports).
Several candidates open a picker with the signature and origin. If the name
already resolves without an import (a member of the enclosing class or its
supertypes, a declaration in this file), you get a note instead.

**`<leader>co`** removes unused imports and sorts the rest the way ktlint and
IntelliJ do: everything else, then `java`, `javax`, `kotlin`, then aliases. If
there are comments among the imports, it only removes the unused lines.

**Unused imports** are greyed out as you edit, like an LSP would show them
(a `vim.diagnostic` hint, tagged unnecessary). An import counts as unused when
the code never mentions its name: comments and strings don't count, a KDoc
`[Link]` does. A repeated import counts as unused too. Star imports and
operator conventions (`getValue`, `plus`, `invoke`, `componentN`, …) are
never flagged, because syntax uses them, not their names. The hints update
after each edit outside insert mode. Turn them off with
`unused_imports = false`.

### Structure and search

- **`<leader>cs`** (IntelliJ `Ctrl+F12`) shows the outline of the file:
  top-level declarations and class members, private / protected / internal
  ones marked with a UML sigil, with kind icons. Braces in comments and
  strings don't confuse it.
- **`<leader>cS`** (IntelliJ `Ctrl+N`) is a live search over the project's
  top-level classes, objects, interfaces, enums and functions.
- **`<leader><leader>`** finds files through Telescope or snacks, whichever
  is there.
- **`<leader>ka`** switches between `X.kt` and `XTest.kt`, wherever in the
  module the test lives. If there's no test yet, it offers to create one.
- **`<leader>kc`** copies the fully qualified name of the declaration under
  the cursor (`pkg.Owner.member`), or of the file (`package.ClassName`), to
  the `+` register.

Search in the `<leader>cs` / `<leader>cS` pickers ignores case.

### Library sources

`gd` can only go into a library whose sources are on disk. The plugin finds
`*-sources.jar` files (in the Gradle cache and `~/.m2`) or gets them from
Gradle, and extracts them into a read-only cache.

**`:KotlinSourcesSync`** (`<leader>ks`) fetches the sources of every library on
the build's compile classpaths: all modules, tests too, every variant. It's
like IntelliJ's Gradle sync with "Download sources". It runs Gradle (the
wrapper, through an `--init-script` task, with no changes to your project),
which resolves each library's `sources` artifact and downloads what isn't
cached yet. From then on, the project sees exactly those libraries, at the
versions Gradle resolved.

**It runs by itself** on the first Kotlin buffer of a Gradle build, in the
background, when:

- the build was never synced, or
- a build script changed since the last sync: settings, the root or a
  module's `build.gradle(.kts)`, `gradle/libs.versions.toml`.

It only speaks up when it extracted something new. Startups without a Kotlin
file and buffers outside a Gradle build don't touch the disk. Turn this off
with `auto_sync = false`.

**On demand.** If you `gd` on an imported class of a library whose sources
aren't there (`no declaration of 'X' in a.b.c`), the plugin fetches them
first, like IntelliJ's "Download Sources":

- if a `*-sources.jar` for the package's group is already in the Gradle cache,
  it's extracted right away;
- otherwise Gradle finds the classpath jar or aar that holds the class (for a
  top-level `fun` / `val`, the ones with classes in its package) and resolves
  its `sources` artifact through the project's repositories.

Then it jumps, and a library the build got since its last sync joins its
classpath. JDK and Android packages, and packages your project declares, are
skipped. "No sources published" is remembered for the session.

**`:KotlinSourcesClear`** removes extracted sources that no synced build has on
its classpath: other builds' leftovers, older versions. `gd` will fetch one
again if it ever needs it. `:KotlinSourcesClear!` clears the whole cache,
including the JDK and SDK extracts and the sync records.

**Versions.** The cache can hold several versions of a library, for example
three `kotlin-stdlib`s from different projects. A synced build only sees its
own classpath. Either way, a file searches only one version of each library:
the one its build pins (`libs.versions.toml`, a `"g:a:v"` in a build script,
the Kotlin plugin's version for `kotlin-*`), otherwise the newest. Of the
platform variants (`-android`, `-desktop`, `-jvm`, `-ios*`, …), it searches
the ones the file's platform uses. Common code searches only the common
artifact.

A library is identified by its artifact name and the root package of its
sources (by group, for a jar without sources), so `androidx.core:core` and
some other `core` don't get mixed up. A file that several searched
directories ship counts once. That happens with KMP common sources in `x` and
`x-jvm`, or with SDK sources and stubs.

### Android SDK and JDK

**Android.** In Android code, `gd`, `K` and `grt` also reach the platform:
`Build.VERSION.SDK_INT`, `Color.TRANSPARENT`, `Intent.ACTION_VIEW`, members
inherited from `Activity` / `Context`, Java getters used as properties
(`intent`, `window`, `i.action`, `context.packageName`), `java.lang.*`.
Android code means a module with the Android plugin, or the `android*` source
sets of a KMP module.

- **Which SDK:** `android_sdk`, else `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`,
  `sdk.dir` in `local.properties`, `~/Android/Sdk`.
- **Which level:** the module's `compileSdk`, whether it's a literal,
  `compileSdk { version = release(n) }`, or comes through `libs.versions.toml`.
- **Where it searches:** `sources/android-<compileSdk>`, else the nearest
  installed level. Then the `android-stubs-src.jar` of the compileSdk platform
  (exact signatures, no bodies) covers what those sources lack: a class or
  member newer than them, `android.R`, `Manifest.permission`.

A class from a package the file doesn't import isn't offered. Neither is
anything outside the public API (`com.android.internal`, `@hide`, whatever the
stubs lack). If the sources don't match compileSdk, the first jump tells you,
along with the `sdkmanager "sources;android-<n>"` command that installs the
right ones.

**JDK.** In JVM code, the same goes for `java.*` / `javax.*`: `Instant.now()`,
`ChronoUnit.DAYS`, `java.sql.Connection`, `Thread`. JVM code means a module
without the Android plugin, or the `jvm*` / `desktop*` source sets of a KMP
module.

- **Which JDK:** the one the build's toolchain asks for (`jvmToolchain(n)`,
  `JavaLanguageVersion.of(n)`, `JvmTarget.JVM_n`, `JavaVersion.VERSION_n`).
  It's looked for under `$JAVA_HOME`, `~/.sdkman/candidates/java`,
  `/usr/lib/jvm` and `java` on `PATH`. Without a toolchain, `$JAVA_HOME`, else
  the newest. If a different JDK than the toolchain's is used, you're told
  once.
- **What's extracted:** its `lib/src.zip`, only the `jdk_modules`, once, into
  the same cache: `java.*` / `javax.*`, not `jdk.internal` or `sun`.

Kotlin's own types come first: `String`, `Exception` and `List` go to the
stdlib. Members of Java types that Kotlin maps to its own (`java.lang.String`,
`Object`, `Integer`, `java.util.List`, …) aren't candidates.

### Run and test

**`<leader>kr` / `<leader>kR`** open a terminal at the bottom and run. From the
file, the runner walks up to the nearest project root and uses the first of
these that fits:

1. `./gradlew run` (or `gradle run` without a wrapper)
2. `make run`
3. `python3 manage.py runserver`

`<leader>kr` also passes `-PmainClass=<package>.<File>Kt`. If you want it to
run *this* file's `main`, wire the property into your build once:

```kotlin
application { mainClass = providers.gradleProperty("mainClass").orElse("com.example.MainKt") }
```

Without that, it runs the project's configured main. The property name can be
changed with `run.main_property`.

**`<leader>kt` / `<leader>kT`** run Gradle tests for the file or the project
(a module picker in a multi-module build).

- A temporary `--init-script` (your project isn't changed) logs every test as
  `PASSED` / `FAILED` and prints a total.
- When the run finishes, you get a summary, and failed tests from the JUnit
  XML go into the quickfix list.
- The task is worked out from the test file's source set without asking
  Gradle: `src/commonTest` or `src/jvmTest` mean `jvmTest`, `src/test` means
  `test`. Otherwise it goes by the project's shape: KMP means `jvmTest`,
  anything else `test`, which on Android covers all unit-test variants.
- Reruns are forced by clearing the module's `build/test-results`.

You can override all of this with `test = { task, rerun, quickfix }`.

**Compiler errors.** Whatever kotlinc reports while a run or a test compiles
(`e:` / `w:` lines from Gradle, `path:line:col: error:` from plain `kotlinc`)
shows up as `vim.diagnostic` errors and warnings in those files, so `]e` /
`]d`, `<leader>cd` and the sign column work. They stay until the next run
replaces them.

### Folds and highlighting

With treesitter folding (`foldexpr = "v:lua.vim.treesitter.foldexpr()"`), more
things fold than nvim-treesitter folds on its own: KDoc and `/* */` comments,
multi-line call arguments, the parameters of a `fun`, `try` / `catch` /
`finally` blocks, multi-line strings.

A `$name` template in a string is highlighted like `${...}` already is: `$` as
`@punctuation.special`, the name as `@variable`. nvim-treesitter leaves it as
plain string text.

Both come from the plugin's `queries/kotlin/`. A file you opened before the
plugin loaded (`event = "VeryLazy"`) picks them up when it does.

### Breadcrumbs

`require("kotlin-lite.breadcrumbs").get()` tells you where the cursor is, for
example `Counter › Companion › zero`: the classes and the function or property
around it. Outside Kotlin and Java buffers it's `""`. Put it in the
statusline, where LazyVim shows LSP symbols for other languages:

```lua
{
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
        table.insert(opts.sections.lualine_c, {
            function() return require("kotlin-lite.breadcrumbs").get() end,
        })
    end,
}
```

or in the winbar: `vim.o.winbar = "%{v:lua.require'kotlin-lite.breadcrumbs'.get()}"`.

### snacks.nvim explorer

[snacks.nvim] is optional. The plugin never loads it on its own and works fine
without it. If you have it and leave `snacks_integration = true` (the
default), the explorer gets a few Kotlin-friendly keys:

| Key | What it does |
| --- | --- |
| `<leader>km` | Compact middle packages (`com/example/foo` → `com.example.foo`); works globally too |
| `a` | Add a file or directory; a new `.kt` file gets its `package` and `class` |
| `<leader>cR` | Kotlin-aware rename, the same as in a buffer (not for a multi-selection) |
| `Y` | Copy file(s) to the system clipboard (`osascript` on macOS, `Set-Clipboard` on Windows, `wl-copy` / `xclip` / `xsel` on Linux) |
| `zo` / `zO` | Open a directory, one level / recursively |
| `zA` / `zM` | Toggle recursively / close all |
| `zR` | Open all directories |
| `<A-a>` | Git: add to the index |

Hook it into your snacks config:

```lua
{
    "folke/snacks.nvim",
    opts = {
        picker = {
            sources = {
                explorer = require("kotlin-lite").explorer_opts(),
            },
        },
    },
}
```

`<leader>ke` reveals the current file in the explorer. Without snacks it shows
a warning; set `snacks_integration = false` to make it do nothing instead.

### IntelliJ keymaps

With `intellij_keymaps = true`, Kotlin buffers also get:

| Key | What it does |
| --- | --- |
| `<C-n>` | Find files |
| `<C-e>` | Recent files |
| `<S-F6>` | Rename |
| `<C-A-h>` | Incoming calls |
| `<C-A-l>` | Format |
| `<C-A-o>` | Organize imports |
| `<C-S-t>` | Go to test |
| `<M-CR>` | Auto-import (Alt+Enter) |
| `<C-/>` | Toggle comment (the built-in `gc`) |
| `<S-F10>` / `<C-S-F10>` | Run the project / this file |
| `<C-S-->` / `<C-S-=>` | Collapse / expand all folds (`zM` / `zR`) |

Some of them (`<C-A-l>`, `<M-CR>`, `<C-/>`, `<C-S-...>`) only work if your
terminal sends those key sequences. kitty, WezTerm and Ghostty do. A bare TTY
may silently drop them.

## Configuration

Everything below is the default. Pass only what you want to change.

```lua
require("kotlin-lite").setup({
    filetypes = { "kotlin" },
    cache_dir = vim.fn.stdpath("cache") .. "/kotlin-lite-jars",
    jar_search_roots = {
        "~/.gradle/caches/modules-2/files-2.1",
        "~/.m2/repository",
    },
    formatprg = "ktlint --format --stdin --log-level=none", -- used by <leader>cf
    format_on_equal = false,                -- also map `=` to whole-buffer format
    symbols = { icons = { --[[ class/interface/object/companion/fun/field ]] } },
    intellij_keymaps = false,               -- add the IntelliJ keys on top of the vim ones
    snacks_integration = true,              -- snacks.nvim explorer keys, if snacks is installed
    auto_sync = true,                       -- :KotlinSourcesSync when the build changed
    android_sdk = nil,                      -- SDK dir (nil: $ANDROID_HOME, ...; false: none)
    jdk = true,                             -- JDK sources (true: the toolchain's; a JDK home; false: none)
    jdk_modules = { "java.base", "java.logging", "java.net.http", "java.sql" },
    project_keymaps = true,                 -- project keys work globally in a gradle project
    tagfunc = true,                         -- <C-]> / :tag / :ptag resolve like gd
    highlight_references = true,            -- highlight the symbol's occurrences on CursorHold
    unused_imports = true,                  -- grey out imports nothing uses
    textobjects = false,                    -- af / if (fun), ac / ic (class / object)
    run = {
        height = 15,                        -- terminal height
        main_property = "mainClass",        -- gradle -P property for <leader>kr
    },
    keymaps = {
        goto_definition    = "gd",
        goto_type_definition = "grt",
        goto_implementation = "gri",
        goto_super         = "<leader>ku",
        hover              = "K",
        signature_help     = "gK",
        signature_help_insert = "<C-s>",  -- insert mode
        find_usages        = { "gu", "grr" },
        incoming_calls     = "<leader>kh",
        next_reference     = "]r",
        prev_reference     = "[r",
        rename             = "<leader>cr",
        rename_file        = "<leader>cR",
        format             = "<leader>cf",
        organize_imports   = "<leader>co",
        file_structure     = "<leader>cs",
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>ke",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = "<leader>ki",
        run_file           = "<leader>kr",
        run_project        = "<leader>kR",
        sources            = "<leader>ks",
        toggle_compact     = "<leader>km",
        find_files         = "<leader><leader>",
    },
})
```

A few notes:

- **Keymaps.** Set a keymap to `false` to turn it off. A value can be one key
  or a list of keys.
- **Where the keys apply.** Most keys exist only in Kotlin buffers, so your
  LSP keys elsewhere (`grr` included) stay as they are. The exceptions work
  without a `.kt` buffer open, and inside the snacks explorer:
  - `<leader>kR`, `<leader>ks` and `<leader>ke` in a Gradle project (turn off
    with `project_keymaps = false`);
  - `<leader>km`, whenever snacks is integrated.
- **Formatting.** `=` keeps its usual meaning unless `format_on_equal = true`.
- **Icons.** The outline icons are nerd-font codicons. Set `symbols.icons` to
  plain text if you don't use a nerd font.

## Limitations

It reads code; it doesn't compile it. Most of the time that's enough, but it
helps to know where it stops:

- **Overloads that differ only by argument types**, like `LocalDate.now(zone)`
  (`ZoneId` or `Clock`), open a picker. The plugin narrows overloads by the
  number and shape of the arguments, not by their types.
- **Some receivers' types stay unknown**: an implicit lambda receiver, a long
  chain of generic calls. Then `gd` shows the candidates, and rename leaves
  those lines unchecked for you to decide.
- **`gri` on a method** finds Kotlin `override`s, not Java `@Override`s inside
  library or SDK sources. On types it handles Java fine.
- **A library without published sources** can't be opened: there's nothing to
  extract, so `gd` stops at the import.

## Project layout

<details>
<summary>What's where in the code</summary>

```
lua/kotlin-lite/
├── init.lua      -- setup()/init(), autocmds, user commands
├── config.lua    -- defaults + option merging
├── jars.lua      -- *-sources.jar discovery, extraction, a project's classpath / versions, read-only cache
├── fetch.lua     -- sources from gradle: :KotlinSourcesSync, gd on a library class without sources
├── sdk.lua       -- platform sources: Android SDK (compileSdk) / JDK (toolchain)
├── search.lua    -- ripgrep (+ parallel / cancellable engine) + Kotlin decl patterns + in-buffer search
├── scope.lua     -- file structure: comments / strings masked, {} blocks, where a decl is visible
├── resolve.lua   -- gd / grt / K / gK / gri / super / tagfunc: receivers (incl. a.b.c, f().x),
│                    named args, overloads, owner classes, ranking, declaration types;
│                    each result carries its symbol (kind, owners, package, visibility, expect/actual)
├── reader.lua    -- file reads for one request, shared by resolve and impl
├── resources.lua -- R.<type>.x / Res.<type>.x -> res/ and composeResources/
├── gradle.lua    -- BuildConfig.X, libs.x, projects.x -> build files, version catalog, modules
├── usages.lua    -- gu / rename: the occurrences that mean the resolved declaration
├── rename_preview.lua -- rename: the checklist of occurrences before applying
├── highlight.lua -- occurrences of the symbol under the cursor, highlighted on CursorHold
├── calls.lua     -- incoming calls: the function / property a usage is in
├── breadcrumbs.lua -- Counter › Companion › zero for the statusline
├── textobj.lua   -- af / if / ac / ic from scope blocks
├── defs.lua      -- gd picker rows: one version, one copy of a file, expect/actual columns
├── imports.lua   -- file header (package/imports) -> candidate ranking for gd / K / gK
├── organize.lua  -- unused imports (hints) and organize imports
├── impl.lua      -- gri: class header parsing, subtypes / overrides / actuals of a resolved symbol
├── actions.lua   -- gd / K / gK / gr / rename / rename-file / structure / symbols / alternate / fqname / auto-import / format
├── runner.lua    -- run + test (bottom terminal, gradle init-script, quickfix)
├── compiler.lua  -- kotlinc errors / warnings in a run's output -> vim.diagnostic
├── keymaps.lua   -- buffer-local + global keymap attachment
├── picker.lua    -- case-insensitive list picker (snacks, else vim.ui.select)
└── snacks.lua    -- optional snacks.nvim explorer integration (loaded lazily)
plugin/kotlin-lite.lua  -- startup bootstrap
queries/kotlin/folds.scm -- extra treesitter folds (comments, arguments, try / catch)
queries/kotlin/highlights.scm -- `$name` string templates highlighted
tests/                  -- fixtures, interactive harness, busted specs (*_spec.lua)
```

</details>

To try it live or run the tests, see [`tests/README.md`](tests/README.md).

[snacks.nvim]: https://github.com/folke/snacks.nvim
