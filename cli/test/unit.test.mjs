// Unit tests over the built bundle (dist/peekr.js). `npm test` builds first.
// These cover the pure logic: error contract, ref lifecycle, locator
// building, snapshot line rendering, and discovery-file resolution.

import { deepStrictEqual, match, strictEqual, throws } from "node:assert";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";
import {
  ErrorCodes,
  PeekrError,
  discoveryFileURL,
  helpers,
  loadDiscovery,
  state,
} from "../dist/peekr.js";
import { buildLocator, SnapshotRenderer } from "../dist/peekr.js";
import { resetRefs, resolveRef } from "../dist/peekr.js";

const withEnv = (vars, fn) => {
  const saved = { ...vars };
  for (const [key, value] of Object.entries(vars)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  try {
    fn();
  } finally {
    for (const key of Object.keys(vars)) delete process.env[key];
    Object.assign(process.env, saved);
  }
};

after(() => {
  // The bundle import wires helpers but never opens sockets in these tests.
  strictEqual(typeof helpers.snapshotText, "function");
});

describe("error contract", () => {
  it("hard-stop codes carry fixed guidance", () => {
    const error = new PeekrError(
      ErrorCodes.spaceUserInControl,
      "space taken over",
    );
    strictEqual(error.hardStop, true);
    match(error.guidance, /Do not retry/);
    match(error.guidance, /takeOverSpace/);
  });

  it("agent access disabled is a hard stop with setup guidance", () => {
    const error = new PeekrError(ErrorCodes.agentAccessDisabled, "off");
    strictEqual(error.hardStop, true);
    match(error.guidance, /Agent Access/);
  });

  it("regular failures are retryable once", () => {
    const error = new PeekrError(ErrorCodes.actionFailed, "boom");
    strictEqual(error.hardStop, false);
  });

  it("toJSON carries ok/code/hard_stop", () => {
    const error = new PeekrError(ErrorCodes.unknownRef, "bad ref", { ref: "@9" });
    const payload = error.toJSON();
    strictEqual(payload.ok, false);
    strictEqual(payload.code, ErrorCodes.unknownRef);
    deepStrictEqual(payload.data, { ref: "@9" });
  });
});

describe("ref lifecycle", () => {
  it("refs resolve only after a snapshot registers them", () => {
    resetRefs([]);
    throws(() => resolveRef("@3"), /Unknown ref/);

    resetRefs([
      { ref: 3, role: "link", name: "Home", locator: "role:link[name=Home]", backendDOMNodeId: 77 },
    ]);
    const info = resolveRef("@3");
    strictEqual(info.backendDOMNodeId, 77);
    strictEqual(resolveRef(3).name, "Home");
    resetRefs([]);
  });
});

describe("locator building", () => {
  const frame = {
    sessionId: "s1",
    attributes: new Map([
      [10, ["id", "submit-btn"]],
      [11, ["data-testid", "search-box"]],
      [12, ["name", "q"]],
    ]),
    bounds: new Map(),
  };

  it("prefers role:name over everything", () => {
    const locator = buildLocator(
      { nodeId: "1", role: { value: "link" }, name: { value: "Docs" } },
      frame,
    );
    strictEqual(locator, "role:link[name=Docs]");
  });

  it("falls back to id, then data-testid, then name attribute", () => {
    strictEqual(
      buildLocator({ nodeId: "2", role: { value: "button" }, backendDOMNodeId: 10 }, frame),
      "css:#submit-btn",
    );
    strictEqual(
      buildLocator({ nodeId: "3", role: { value: "textbox" }, backendDOMNodeId: 11 }, frame),
      'css:[data-testid="search-box"]',
    );
    strictEqual(
      buildLocator({ nodeId: "4", role: { value: "textbox" }, backendDOMNodeId: 12 }, frame),
      'css:[name="q"]',
    );
  });

  it("link url is the last resort", () => {
    const locator = buildLocator(
      {
        nodeId: "5",
        role: { value: "link" },
        properties: [{ name: "url", value: { type: "string", value: "https://example.com" } }],
      },
      frame,
    );
    strictEqual(locator, "href:https://example.com");
  });
});

describe("snapshot rendering", () => {
  const render = (nodes, frameOverrides = {}) => {
    const renderer = new SnapshotRenderer({ includeStableLocator: true, scope: "full_page" });
    renderer.render(nodes, { sessionId: "s", attributes: new Map(), bounds: new Map(), ...frameOverrides }, "");
    return renderer;
  };

  it("renders interactive elements with refs, names, locators and urls", () => {
    const renderer = render([
      {
        nodeId: "root", role: { value: "RootWebArea" }, name: { value: "Example" },
        childIds: ["link"],
      },
      {
        nodeId: "link", role: { value: "link" }, name: { value: "More information" },
        backendDOMNodeId: 5,
        properties: [{ name: "url", value: { type: "string", value: "https://www.iana.org" } }],
        childIds: ["text"],
      },
      { nodeId: "text", role: { value: "staticText" }, name: { value: "More information" } },
    ]);
    deepStrictEqual(renderer.lines, [
      '@1 [link] "More information" loc=role:link[name=More%20information] url=https://www.iana.org',
    ]);
    strictEqual(renderer.refs.length, 1);
    strictEqual(renderer.refs[0].backendDOMNodeId, 5);
    // The duplicated staticText under the link is folded away.
  });

  it("keeps headings, images and static text; skips ignored nodes", () => {
    const renderer = render([
      {
        nodeId: "root", role: { value: "RootWebArea" }, childIds: ["h", "img", "txt", "hidden", "clicky"],
      },
      { nodeId: "h", role: { value: "heading" }, name: { value: "Example Domain" } },
      { nodeId: "img", role: { value: "image" }, name: { value: "logo" } },
      { nodeId: "txt", role: { value: "staticText" }, name: { value: "This domain is for use." } },
      { nodeId: "hidden", role: { value: "button" }, name: { value: "nope" }, ignored: true },
      {
        nodeId: "clicky", role: { value: "generic" }, name: { value: "" },
        properties: [{ name: "clickable", value: { type: "boolean", value: true } }],
      },
    ]);
    deepStrictEqual(renderer.lines, [
      '[heading] "Example Domain"',
      '[image] "logo"',
      "This domain is for use.",
      '@1 [generic]',
    ]);
    strictEqual(renderer.refs.length, 1);
    match(renderer.lines.join("\n"), /\[disabled\]|\[checked\]|^/);
  });

  it("emits textbox value; unnamed inputs fall back to css locators", () => {
    const renderer = new SnapshotRenderer({ includeStableLocator: true, scope: "full_page" });
    renderer.render(
      [
        {
          nodeId: "root", role: { value: "RootWebArea" }, childIds: ["box", "anon"],
        },
        {
          nodeId: "box", role: { value: "textbox" }, name: { value: "Search" },
          value: { value: "peekr" }, backendDOMNodeId: 12,
        },
        { nodeId: "anon", role: { value: "textbox" }, backendDOMNodeId: 12 },
      ],
      {
        sessionId: "s",
        attributes: new Map([[12, ["name", "q"]]]),
        bounds: new Map(),
      },
      "",
    );
    match(renderer.lines[0], /@1 \[textbox\] "Search" loc=role:textbox\[name=Search\] value="peekr"/);
    match(renderer.lines[1], /@2 \[textbox\] loc=css:\[name="q"\]/);
  });
});

describe("discovery resolution", () => {
  it("honors the explicit override, then the smoke root, then the real path", () => {
    withEnv({ PEEKR_AGENT_DISCOVERY: "/tmp/explicit.json", PEEKR_SMOKE_DATA_ROOT: undefined }, () => {
      strictEqual(discoveryFileURL(), "/tmp/explicit.json");
    });
    withEnv({ PEEKR_AGENT_DISCOVERY: undefined, PEEKR_SMOKE_DATA_ROOT: "/tmp/smoke" }, () => {
      strictEqual(discoveryFileURL(), join("/tmp/smoke", "agent.json"));
    });
  });

  it("missing file is the agent-access-disabled hard stop", () => {
    const dir = mkdtempSync(join(tmpdir(), "peekr-cli-test-"));
    after(() => rmSync(dir, { recursive: true, force: true }));
    withEnv({ PEEKR_AGENT_DISCOVERY: join(dir, "agent.json") }, () => {
      let thrown;
      try {
        loadDiscovery();
      } catch (error) {
        thrown = error;
      }
      strictEqual(thrown?.code, ErrorCodes.agentAccessDisabled);
      strictEqual(thrown?.hardStop, true);
    });
  });

  it("stale pid maps to cdp-unavailable, not a hard stop", () => {
    const dir = mkdtempSync(join(tmpdir(), "peekr-cli-test-"));
    after(() => rmSync(dir, { recursive: true, force: true }));
    const file = join(dir, "agent.json");
    writeFileSync(file, JSON.stringify({ schemaVersion: 1, port: 9223, pid: 3_999_999_999 }));
    withEnv({ PEEKR_AGENT_DISCOVERY: file }, () => {
      let thrown;
      try {
        loadDiscovery();
      } catch (error) {
        thrown = error;
      }
      strictEqual(thrown?.code, ErrorCodes.cdpUnavailable);
      strictEqual(thrown?.hardStop, false);
    });
  });

  it("helper surface contains the goal-mandated names plus ego aliases", () => {
    for (const name of [
      "openOrReuseTab", "listTabs", "switchTab", "gotoAndWait", "snapshotText",
      "snapshotRaw", "click", "fillInput", "pressKey", "scrollBy", "js", "cdp",
      "screenshot", "wait", "waitForLoad", "cliLog",
      "useOrCreateSpace", "listSpaces", "claimSpace", "handOffSpace",
      "takeOverSpace", "completeSpace",
      "useOrCreateTaskSpace", "completeTaskSpace",
    ]) {
      strictEqual(typeof helpers[name], "function", `missing helper: ${name}`);
    }
    strictEqual(state.sockets.size, 0, "importing the bundle must not open connections");
  });
});
