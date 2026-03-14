#!/usr/bin/env node

import { appendFileSync } from "node:fs";
import https from "node:https";

const APPCAST_URL =
  process.env.CODEX_APPCAST_URL ??
  "https://persistent.oaistatic.com/codex-app-prod/appcast.xml";
const CHANGELOG_URL =
  process.env.CODEX_CHANGELOG_URL ??
  "https://developers.openai.com/codex/changelog?type=codex-app";
const SOURCE_DMG_URL =
  process.env.CODEX_SOURCE_DMG_URL ??
  "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";

function requiredMatch(value, regex, label) {
  const match = value.match(regex);
  if (!match?.[1]) {
    throw new Error(`Unable to parse ${label} from upstream appcast.`);
  }
  return match[1].trim();
}

function setOutput(name, value) {
  const githubOutput = process.env.GITHUB_OUTPUT;
  if (githubOutput) {
    appendFileSync(githubOutput, `${name}=${value}\n`);
  }
}

function fetchText(url) {
  if (typeof fetch === "function") {
    return fetch(url, {
      headers: {
        "user-agent": "codex-rebuild-actions/1.0",
        accept: "application/xml,text/xml;q=0.9,*/*;q=0.8",
      },
    }).then(async (response) => {
      if (!response.ok) {
        throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
      }
      return response.text();
    });
  }

  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          "user-agent": "codex-rebuild-actions/1.0",
          accept: "application/xml,text/xml;q=0.9,*/*;q=0.8",
        },
      },
      (response) => {
        if (!response.statusCode || response.statusCode < 200 || response.statusCode >= 300) {
          reject(
            new Error(
              `Failed to fetch ${url}: ${response.statusCode ?? "unknown"} ${response.statusMessage ?? ""}`.trim(),
            ),
          );
          response.resume();
          return;
        }

        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          body += chunk;
        });
        response.on("end", () => {
          resolve(body);
        });
      },
    );

    request.on("error", reject);
  });
}

const xml = await fetchText(APPCAST_URL);
const firstItem = requiredMatch(xml, /<item>([\s\S]*?)<\/item>/, "first item");
const appVersion = requiredMatch(
  firstItem,
  /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/,
  "sparkle:shortVersionString",
);
const buildNumber = requiredMatch(
  firstItem,
  /<sparkle:version>([^<]+)<\/sparkle:version>/,
  "sparkle:version",
);
const publishedAt = requiredMatch(firstItem, /<pubDate>([^<]+)<\/pubDate>/, "pubDate");
const sourceZipUrl = requiredMatch(firstItem, /<enclosure url="([^"]+)"/, "enclosure url");

const releaseTag = `v${appVersion}`;
const releaseName = `Codex macOS x64 v${appVersion}`;
const assetName = `codex-macos-x64-${appVersion}.dmg`;
const checksumName = `${assetName}.sha256`;

const metadata = {
  appcastUrl: APPCAST_URL,
  changelogUrl: CHANGELOG_URL,
  sourceDmgUrl: SOURCE_DMG_URL,
  sourceZipUrl,
  appVersion,
  buildNumber,
  publishedAt,
  releaseTag,
  releaseName,
  assetName,
  checksumName,
};

for (const [key, value] of Object.entries(metadata)) {
  const outputKey = key.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
  setOutput(outputKey, String(value));
}

process.stdout.write(`${JSON.stringify(metadata, null, 2)}\n`);
