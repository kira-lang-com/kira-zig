@Agents.md

You can check the work at .codex/ if needed.

## Commit conventions

Do NOT add `Co-Authored-By: Claude ...` trailers or any AI/tooling promotional lines to commit messages. Commits are authored solely by the human author.

comptime construct Test {
    sections {
        @Required
        function test -> Any

        @Required
        function expect -> Bool
    }

    lifecycle {
        validate() {
            TestRuntime.run(Self.test, Self.expect)
        }
    }
}

Test EnumCalculation {
    test {
        let value = Direction.left
        return value.rotate()
    }

    expect {
        return result == Direction.up
    }
}