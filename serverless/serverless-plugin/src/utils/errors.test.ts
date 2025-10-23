import { getErrorMessage } from "./errors";

describe("errors utils", () => {
  describe("getErrorMessage", () => {
    it("gets default error message", () => {
      expect(getErrorMessage(new Error("hello"))).toEqual("hello");
    });
    it("convert non-error to string", () => {
      expect(getErrorMessage(5)).toEqual("5");
    });
  });
});
