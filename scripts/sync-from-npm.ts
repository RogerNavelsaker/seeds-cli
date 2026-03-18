const manifestPath = "nix/package-manifest.json";
const manifestFile = Bun.file(manifestPath);
const manifest = await manifestFile.json();
const packageJsonPath = "package.json";
const packageJson = await Bun.file(packageJsonPath).json();

const registryUrl = `https://registry.npmjs.org/${encodeURIComponent(manifest.package.npmName)}`;
const response = await fetch(registryUrl, {
  headers: {
    accept: "application/json",
  },
});

if (!response.ok) {
  throw new Error(`Failed to fetch ${registryUrl}: ${response.status} ${response.statusText}`);
}

const registry = await response.json();
const latestTag = registry["dist-tags"]?.latest;

if (!latestTag) {
  throw new Error(`No latest dist-tag found for ${manifest.package.npmName}`);
}

const latest = registry.versions?.[latestTag];

if (!latest) {
  throw new Error(`No version payload found for ${manifest.package.npmName}@${latestTag}`);
}

const binEntries = Object.entries(latest.bin ?? {});

if (binEntries.length === 0) {
  throw new Error(`No bin entry found for ${manifest.package.npmName}@${latestTag}`);
}

const [binName, entrypoint] = binEntries[0];

manifest.stubbed = false;
manifest.package.version = latest.version;
manifest.binary.upstreamName = binName;
manifest.binary.entrypoint = entrypoint;
manifest.dist.url = latest.dist.tarball;
manifest.dist.hash = latest.dist.integrity;
manifest.meta.description = latest.description ?? manifest.meta.description;
manifest.meta.homepage =
  latest.homepage ??
  registry.homepage ??
  `https://www.npmjs.com/package/${manifest.package.npmName}`;
manifest.meta.licenseSpdx = latest.license ?? manifest.meta.licenseSpdx ?? "unfree";
packageJson.dependencies ??= {};
packageJson.dependencies[manifest.package.npmName] = latest.version;

await Bun.write(`${manifestPath}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`);
await Bun.write(manifestPath, await Bun.file(`${manifestPath}.tmp`).text());
await Bun.file(`${manifestPath}.tmp`).delete();
await Bun.write(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`);

console.log(
  JSON.stringify(
    {
      package: manifest.package.npmName,
      version: manifest.package.version,
      bin: manifest.binary.name,
      upstreamBin: manifest.binary.upstreamName,
      entrypoint: manifest.binary.entrypoint,
    },
    null,
    2,
  ),
);
