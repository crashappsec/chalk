import { binExists, runCommand } from "./os";

describe("os utils", () => {
  describe("runCommand", () => {
    it("returns stdout", () => {
      expect(runCommand("echo -n hello")).toBe("hello");
    });
    it("throws error on >0 exit code", () => {
      expect(() => runCommand("false")).toThrow();
    });
  });

  describe("binExists", () => {
    it("finds ls", () => {
      expect(binExists("ls")).toBeTruthy();
    });
    it("doesnt find haha", () => {
      expect(binExists("haha")).toBeFalsy();
    });
  });
});
