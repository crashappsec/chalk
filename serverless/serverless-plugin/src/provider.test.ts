import { CONFIG_DEFAULTS } from "./config";
import { ARN_PATTERN } from "./helpers";
import { getProvider } from "./provider";
import * as fs from "fs";
import * as path from "path";

describe("provider utils", () => {
  describe("getProvider", () => {
    it("requires service name", async () => {
      expect(
        getProvider(
          CONFIG_DEFAULTS, //
          { name: "aws" },
          {},
          {},
        ),
      ).rejects.toThrow(/required/);
    });
    it("requires zip file to be present", async () => {
      expect(
        getProvider(
          CONFIG_DEFAULTS, //
          { name: "aws" },
          {},
          { serviceName: "service" },
        ),
      ).rejects.toThrow(/\.zip/);
    });

    describe("with zip file", () => {
      const zipPath = path.resolve(process.cwd(), ".serverless", "service.zip");
      beforeEach(() => {
        fs.mkdirSync(path.join(zipPath, ".."), { recursive: true });
        fs.closeSync(fs.openSync(zipPath, "w"));
      });
      afterEach(() => {
        fs.unlinkSync(zipPath);
      });
      it("returns full provider params", async () => {
        expect(
          getProvider(
            CONFIG_DEFAULTS, //
            { name: "aws" },
            {},
            { serviceName: "service" },
          ),
        ).resolves.toStrictEqual({
          region: "us-east-1",
          memorySize: 1024,
          dustExtensionArn: expect.stringMatching(ARN_PATTERN),
          isChalkAvailable: true,
          zipPath,
        });
      });
    });
  });
});
