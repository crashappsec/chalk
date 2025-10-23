import { getVersionlessArn, rsplit } from "./strings";

describe("string utils", () => {
  describe("rsplit", () => {
    it("should split by the right delimiter", () => {
      expect(rsplit("1:2:3:4:5", ":", 1)).toStrictEqual(["1:2:3:4", "5"]);
      expect(rsplit("1:2:3:4:5", ":", 2)).toStrictEqual(["1:2:3", "4", "5"]);
    });
  });

  describe("getVersionlessArn", () => {
    it("strip out the version from the verionsed extension arn", () => {
      expect(getVersionlessArn("arn:aws:lambda:us-east-1:12345:layer:dust:7")).toStrictEqual(
        "arn:aws:lambda:us-east-1:12345:layer:dust",
      );
    });
  });
});
