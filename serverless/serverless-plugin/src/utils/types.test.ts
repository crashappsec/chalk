import { nonNullable } from "./types";

describe("typescript utils", () => {
  describe("nonNullable", () => {
    it("should remove undefined values", () => {
      expect(nonNullable({ foo: "bar", baz: undefined })).toStrictEqual({ foo: "bar" });
    });
    it("should remove null values", () => {
      expect(nonNullable({ foo: "bar", baz: null })).toStrictEqual({ foo: "bar" });
    });
  });
});
