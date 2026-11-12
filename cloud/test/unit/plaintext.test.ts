import { describe, expect, it } from "vitest";
import { toPlainText } from "../../src/plaintext";

describe("toPlainText (text-message replies)", () => {
  it("strips headings, emphasis, bullets and code formatting", () => {
    const md = "## Today\n\n**Dentist** at 9am — bring your *insurance card*.\n\n- Call Sam\n- Pay rent\n\nUse `git pull` first.";
    expect(toPlainText(md)).toBe("Today\n\nDentist at 9am — bring your insurance card.\n\nCall Sam\nPay rent\n\nUse git pull first.");
  });
  it("keeps links readable and numbered lines intact", () => {
    expect(toPlainText("See [the syllabus](https://canvas.example.edu/s) or https://x.com")).toBe("See the syllabus (https://canvas.example.edu/s) or https://x.com");
    expect(toPlainText("1. First\n2. Second")).toBe("1. First\n2. Second");
  });
  it("does not mangle ordinary prose with underscores, asterisks or math", () => {
    expect(toPlainText("Rate is 5 * 3 = 15, file my_notes_v2.txt")).toBe("Rate is 5 * 3 = 15, file my_notes_v2.txt");
    expect(toPlainText("Got it — I'll keep replies short.")).toBe("Got it — I'll keep replies short.");
  });
  it("flattens code fences and tables", () => {
    expect(toPlainText("```js\nconst a = 1;\n```")).toBe("const a = 1;");
    expect(toPlainText("| Day | Task |\n|---|---|\n| Mon | Lab |")).toBe("Day, Task\nMon, Lab");
  });
});
