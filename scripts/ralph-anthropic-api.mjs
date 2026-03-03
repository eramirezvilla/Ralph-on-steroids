#!/usr/bin/env node
/**
 * Ralph Anthropic API wrapper. Used when running Ralph with --tool api.
 * Reads prompt from file (first arg), calls Anthropic Messages API, prints response to stdout.
 * Requires: ANTHROPIC_API_KEY. Optional: ANTHROPIC_MODEL (default claude-sonnet-4-20250514).
 */

import Anthropic from '@anthropic-ai/sdk';
import { readFileSync } from 'fs';

const MODEL = process.env.ANTHROPIC_MODEL || 'claude-sonnet-4-20250514';
const MAX_RETRIES = 3;

function getPromptContent(filePath) {
  const content = readFileSync(filePath, 'utf8');
  if (!content || !content.trim()) {
    throw new Error('Prompt file is empty');
  }
  return content;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function callApi(client, promptContent) {
  const message = await client.messages.create({
    model: MODEL,
    max_tokens: 16384,
    messages: [{ role: 'user', content: promptContent }],
  });

  const textBlock = message.content?.find((b) => b.type === 'text');
  return textBlock ? textBlock.text : '';
}

async function main() {
  if (!process.env.ANTHROPIC_API_KEY) {
    console.error('Error: ANTHROPIC_API_KEY is not set.');
    process.exit(1);
  }

  const promptFile = process.argv[2];
  if (!promptFile) {
    console.error('Usage: ralph-anthropic-api.mjs <prompt-file>');
    process.exit(1);
  }

  let promptContent;
  try {
    promptContent = getPromptContent(promptFile);
  } catch (err) {
    console.error('Error reading prompt file:', err.message);
    process.exit(1);
  }

  const client = new Anthropic();

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      const text = await callApi(client, promptContent);
      process.stdout.write(text);
      process.exit(0);
    } catch (err) {
      const status = err?.status || err?.httpStatus;
      const is429 = status === 429;
      const headers = err?.responseHeaders || err?.headers || {};
      const getHeader = (name) => (headers?.get ? headers.get(name) : headers?.[name] ?? headers?.[name.toLowerCase()]);
      const retryAfter = getHeader('retry-after') || getHeader('Retry-After');

      if (is429 && attempt < MAX_RETRIES) {
        let waitSec = 60;
        if (retryAfter) {
          const n = parseInt(retryAfter, 10);
          if (!isNaN(n)) waitSec = n;
        }
        console.error(`Rate limited (429). Waiting ${waitSec}s before retry ${attempt + 1}/${MAX_RETRIES}...`);
        await sleep(waitSec * 1000);
        continue;
      }

      if (is429) {
        console.error('Rate limit reached. Resets in 15 minutes or check Retry-After.');
        process.stdout.write('rate limit\nusage limit\n');
        process.exit(1);
      }

      console.error('API error:', err.message || err);
      process.exit(1);
    }
  }
}

main();
