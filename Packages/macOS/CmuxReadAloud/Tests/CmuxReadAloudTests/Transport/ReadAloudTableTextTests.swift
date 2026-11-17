import Foundation
import Testing
@testable import CmuxReadAloud

struct ReadAloudTableTextTests {
    @Test func terminalCommandTableReadsCellsInsteadOfBorders() throws {
        let selection = """
        ┌────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
        │ Part                       │ Meaning                                                                                                                     │
        ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
        │ kubectl                    │ Kubernetes command-line tool. Uses the cluster and credentials selected by your current kubeconfig context.                 │
        ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
        │ exec                       │ Starts a new command inside a running container—not on your laptop.                                                         │
        ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
        │ -n coding-agent-hq-runtime │ Looks in the Kubernetes namespace named coding-agent-hq-runtime.                                                            │
        ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
        │ -it                        │ Combines -i (keep standard input open so you can type into the program) and -t (allocate a terminal for interactive use).   │
        ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
        │ omp-campaign-editor        │ The target pod name.                                                                                                        │
        ├────────────────────────────┼───────────────────────────────────
        """
        #expect(try ReadAloudTableText.prepare(selection) == """
        Part. Meaning.
        kubectl. Kubernetes command-line tool. Uses the cluster and credentials selected by your current kubeconfig context.
        exec. Starts a new command inside a running container—not on your laptop.
        -n coding-agent-hq-runtime. Looks in the Kubernetes namespace named coding-agent-hq-runtime.
        -it. Combines -i (keep standard input open so you can type into the program) and -t (allocate a terminal for interactive use).
        omp-campaign-editor. The target pod name.

        """)
    }

    @Test func wrappedCellsStayWithTheirOwnRowAndColumn() throws {
        let selection = """
        │ First │ A sentence that │ Third column │
        │       │ wraps here.     │ also wraps.  │
        ├───────┼─────────────────┼──────────────┤
        │       │ Separate row.   │ End.         │
        │ Next  │ Another row.    │ Last.        │
        """
        #expect(try ReadAloudTableText.prepare(selection) == """
        First. A sentence that wraps here. Third column also wraps.
        Separate row. End.
        Next. Another row. Last.

        """)
    }

    @Test func partialSelectionDoesNotInventHeadersOrLoseTheLastCell() throws {
        #expect(try ReadAloudTableText.prepare("│ -it │ Keep input open\n├─────┼────")
            == "-it. Keep input open.\n")
    }

    @Test func adjacentHeavyAndDoubleBorderTablesRemainSeparate() throws {
        let selection = """
        ┏━━━━━━┳━━━━━━━━━━━━┓
        ┃ 名前 ┃ 日本語です。 ┃
        ┗━━━━━━┻━━━━━━━━━━━━┛
        ╔══════╦════════════╗
        ║ Next ║ Ready?     ║
        ╚══════╩════════════╝
        """
        #expect(try ReadAloudTableText.prepare(selection) == "名前. 日本語です。\nNext. Ready?\n")
    }

    @Test func ordinaryTextAndShellPunctuationRemainUnchanged() throws {
        let selection = "  kubectl exec -it pod -- sh -c 'a | b'\r\n"
            + "x = -3.5; a || b; echo --help\r\n"
            + "The character │ marks a table edge; ─ is horizontal.\r\n"
            + "│  ├── src\r\n"
            + "| literal pipes | are not automatically a table |\r\n"
        #expect(try ReadAloudTableText.prepare(selection) == selection)
    }

    @Test func onlyTableFurnitureChangesInMixedProseAndCommandCells() throws {
        let selection = "Before:\r\n"
            + "│ printf 'a | b' │ Preserve --help, -3.5 and /tmp/a-b. │\r\n"
            + "After: x | y\r\n"
        #expect(try ReadAloudTableText.prepare(selection)
            == "Before:\r\nprintf 'a | b'. Preserve --help, -3.5 and /tmp/a-b.\nAfter: x | y\r\n")
    }

    @Test func borderOnlySelectionHasNothingToSpeak() throws {
        #expect(try ReadAloudTableText.prepare(" ┌────┬────┐\n ├────┼────\n └────┴────┘") == "")
        #expect(try ReadAloudTableText.prepare("│ --- │ Negative: -3 │") == "---. Negative: -3.\n")
    }
}
