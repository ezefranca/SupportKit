import { describe, expect, it } from "vitest";
import {
  createIssue,
  decodeGitHubTarget,
  GitHubOperationError,
  verifyRepository,
} from "../src/adapters/github/github-issue-tracker";
import type {
  GitHubAdapterConfig,
  GitHubTarget,
} from "../src/adapters/github/github-issue-tracker";

const githubConfiguration: GitHubAdapterConfig = {
  apiBaseURL: "https://api.github.com",
  apiVersion: "2026-03-10",
  appClientID: "unused",
  appPrivateKey: "unused",
};

const target: GitHubTarget = {
  owner: "example",
  repository: "private-repo",
  installationID: "1234",
  repositoryVisibility: "private",
};

describe("GitHub issue-tracker adapter", () => {
  it("classifies transport loss after POST as ambiguous", async () => {
    const operation = createIssue(
      githubConfiguration,
      target,
      "installation-token",
      { title: "Support", body: "body" },
      ["support"],
      () => Promise.reject(new Error("socket closed")),
    );
    await expect(operation).rejects.toMatchObject({
      kind: "ambiguous",
      code: "github_create_ambiguous_transport",
    } satisfies Partial<GitHubOperationError>);
  });

  it("treats a GitHub 503 after create as ambiguous instead of blindly retrying", async () => {
    const operation = createIssue(
      githubConfiguration,
      target,
      "installation-token",
      { title: "Support", body: "body" },
      ["support"],
      () => Promise.resolve(new Response(null, { status: 503 })),
    );
    await expect(operation).rejects.toMatchObject({ kind: "ambiguous", code: "github_create_503" });
  });

  it("accepts only a target-scoped GitHub issue response", async () => {
    const issue = await createIssue(
      githubConfiguration,
      target,
      "installation-token",
      { title: "Support", body: "body" },
      ["support"],
      () => Promise.resolve(Response.json({
        number: 42,
        html_url: "https://github.com/example/private-repo/issues/42",
      }, { status: 201 })),
    );
    expect(issue).toEqual({
      number: 42,
      url: "https://github.com/example/private-repo/issues/42",
    });
  });

  it("rejects issue URLs with authority or URL-component confusion", async () => {
    const invalidURLs = [
      "https://github.com:444/example/private-repo/issues/42",
      [
        "https://",
        "diagnostic-user",
        ":diagnostic-password",
        "@github.com/example/private-repo/issues/42",
      ].join(""),
      "https://github.com/example/private-repo/issues/42?redirect=1",
      "https://github.com/example/private-repo/issues/42#fragment",
    ];

    for (const htmlURL of invalidURLs) {
      const operation = createIssue(
        githubConfiguration,
        target,
        "installation-token",
        { title: "Support", body: "body" },
        ["support"],
        () => Promise.resolve(Response.json({ number: 42, html_url: htmlURL }, { status: 201 })),
      );
      await expect(operation).rejects.toMatchObject({
        kind: "ambiguous",
        code: "github_create_ambiguous_response",
      });
    }
  });

  it("strictly decodes explicit private and public visibility expectations", () => {
    for (const repositoryVisibility of ["private", "public"] as const) {
      expect(decodeGitHubTarget("github", {
        owner: "example",
        repository: "support-reports",
        installationID: "1234",
        repositoryVisibility,
      })).toEqual({
        owner: "example",
        repository: "support-reports",
        installationID: "1234",
        repositoryVisibility,
      });
    }
  });

  it("rejects an omitted, permissive, or unknown visibility policy", () => {
    const baseTarget = {
      owner: "example",
      repository: "support-reports",
      installationID: "1234",
    };
    expect(() => decodeGitHubTarget("github", baseTarget))
      .toThrow("invalid_destination_configuration");
    expect(() => decodeGitHubTarget("github", {
      ...baseTarget,
      repositoryVisibility: "any",
    })).toThrow("invalid_destination_configuration");
    expect(() => decodeGitHubTarget("github", {
      ...baseTarget,
      repositoryVisibility: "private",
      allowPublic: true,
    })).toThrow("invalid_destination_configuration");
  });

  it.each([
    { repositoryVisibility: "private" as const, repositoryIsPrivate: true },
    { repositoryVisibility: "public" as const, repositoryIsPrivate: false },
  ])("accepts a $repositoryVisibility repository only when metadata matches", async ({
    repositoryVisibility,
    repositoryIsPrivate,
  }) => {
    await expect(verifyRepository(
      githubConfiguration,
      { ...target, repositoryVisibility },
      "installation-token",
      () => Promise.resolve(Response.json({
        full_name: "example/private-repo",
        private: repositoryIsPrivate,
        visibility: repositoryVisibility,
      })),
    )).resolves.toBeUndefined();
  });

  it.each([
    { repositoryVisibility: "private" as const, repositoryIsPrivate: false },
    { repositoryVisibility: "public" as const, repositoryIsPrivate: true },
  ])("fails closed when $repositoryVisibility visibility does not match metadata", async ({
    repositoryVisibility,
    repositoryIsPrivate,
  }) => {
    const operation = verifyRepository(
      githubConfiguration,
      { ...target, repositoryVisibility },
      "installation-token",
      () => Promise.resolve(Response.json({
        full_name: "example/private-repo",
        private: repositoryIsPrivate,
        visibility: repositoryIsPrivate ? "private" : "public",
      })),
    );
    await expect(operation).rejects.toMatchObject({
      kind: "permanent",
      code: "github_repository_visibility_mismatch",
    });
  });

  it("rejects unsupported internal repository visibility", async () => {
    await expect(verifyRepository(
      githubConfiguration,
      target,
      "installation-token",
      () => Promise.resolve(Response.json({
        full_name: "example/private-repo",
        private: true,
        visibility: "internal",
      })),
    )).rejects.toMatchObject({
      kind: "permanent",
      code: "github_repository_visibility_mismatch",
    });
  });

  it("retries malformed or incoherent repository visibility metadata", async () => {
    const malformedPayloads = [
      { full_name: "example/private-repo", private: true },
      { full_name: "example/private-repo", private: "true", visibility: "private" },
      { full_name: "example/private-repo", private: false, visibility: "private" },
      { full_name: "example/private-repo", private: true, visibility: "unknown" },
    ];
    for (const payload of malformedPayloads) {
      await expect(verifyRepository(
        githubConfiguration,
        target,
        "installation-token",
        () => Promise.resolve(Response.json(payload)),
      )).rejects.toMatchObject({
        kind: "retryable",
        code: "github_repository_invalid_response",
      });
    }
  });

  it("fails closed when repository metadata identifies another target", async () => {
    await expect(verifyRepository(
      githubConfiguration,
      target,
      "installation-token",
      () => Promise.resolve(Response.json({
        full_name: "example/another-repository",
        private: true,
        visibility: "private",
      })),
    )).rejects.toMatchObject({
      kind: "permanent",
      code: "github_repository_identity_mismatch",
    });
  });
});
