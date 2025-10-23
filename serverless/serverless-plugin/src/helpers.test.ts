import { CONFIG_DEFAULTS } from "./config";
import {
  addDustLambdaExtension,
  ARN_PATTERN,
  fetchDustExtensionArn,
  injectChalkBinary,
  validateFunction,
} from "./helpers";
import { AlreadyHasExtensionError } from "./utils/errors";

describe("helper tests", () => {
  describe("fetchDustExtensionArn", () => {
    it("fetches latest arn", async () => {
      const arn = await fetchDustExtensionArn(CONFIG_DEFAULTS.arnUrlPrefix, "us-east-1");
      const match = arn.match(ARN_PATTERN);
      expect(arn).toMatch(ARN_PATTERN);
      expect(match?.groups?.version).toBeTruthy();
    });
    it("allow to specify arn version", async () => {
      const arn = await fetchDustExtensionArn(CONFIG_DEFAULTS.arnUrlPrefix, "us-east-1", "99999");
      const match = arn.match(ARN_PATTERN);
      expect(arn).toMatch(ARN_PATTERN);
      expect(match?.groups?.version).toBe("99999");
    });
  });

  describe("validateFunction", () => {
    it("allows function without any layers", () => {
      expect(() =>
        validateFunction(
          CONFIG_DEFAULTS, //
          "example",
          { handler: "handler", events: [] },
        ),
      ).not.toThrow();
    });
    it("allows if there are <15 layers", () => {
      expect(() =>
        validateFunction(
          { ...CONFIG_DEFAULTS, awsMaxLayers: 3 }, //
          "example",
          { handler: "handler", events: [], layers: ["1", "2", "3"] },
        ),
      ).toThrow();
    });
  });

  describe("addDustLambdaExtension", () => {
    it("add create layers", () => {
      expect(
        addDustLambdaExtension(
          "arn:aws:lambda:us-east-1:1234:layer:dust:7", //
          "example",
          { handler: "handler", events: [] },
        ),
      ).toHaveProperty("layers", ["arn:aws:lambda:us-east-1:1234:layer:dust:7"]);
    });
    it("add arn to existing layers", () => {
      expect(
        addDustLambdaExtension(
          "arn:aws:lambda:us-east-1:1234:layer:dust:7", //
          "example",
          {
            handler: "handler",
            events: [],
            layers: ["arn:aws:lambda:us-east-1:1234:layer:example:1"],
          },
        ),
      ).toHaveProperty("layers", [
        "arn:aws:lambda:us-east-1:1234:layer:example:1",
        "arn:aws:lambda:us-east-1:1234:layer:dust:7",
      ]);
    });
    it("detect extension is already present", () => {
      expect(() => {
        addDustLambdaExtension(
          "arn:aws:lambda:us-east-1:1234:layer:dust:7", //
          "example",
          {
            handler: "handler",
            events: [],
            layers: ["arn:aws:lambda:us-east-1:1234:layer:dust:1"],
          },
        );
      }).toThrow(AlreadyHasExtensionError);
    });
  });

  describe("injectChalkBinary", () => {
    it("check needed serverless flag is passed to chalk", () => {
      expect(injectChalkBinary("echo", "foo.zip")).toContain("--inject-binary-into-zip");
    });
  });
});
