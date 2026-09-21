# Releasing nim-sqlite

1. Check the latest SQLite security releases and review the version bundled by
   `sqlite3_abi`. Update the dependency floor when a newer SQLite version is
   required for a security fix. Test that version before publishing.
2. Set the version in `nim_sqlite.nimble`, move the pending changelog entries
   into a dated release section, and update the comparison links. Call out
   breaking changes and the tested SQLite version in the release notes.
3. Run the tests and examples locally. Push the release commit and wait for
   all GitHub Actions jobs to pass on that exact commit, including the minimum
   Nim version, supported operating systems, sanitizers, documentation, and
   coverage.
4. Create an annotated `vX.Y.Z` tag at the verified commit and push the tag.
   Build a source archive from that tag and generate a SHA-256 checksum:

   ```sh
   git archive --format=tar --prefix=nim-sqlite-X.Y.Z/ vX.Y.Z |
     gzip -n > nim-sqlite-X.Y.Z.tar.gz
   sha256sum nim-sqlite-X.Y.Z.tar.gz > SHA256SUMS
   ```

5. Publish the GitHub release from the tag with the release notes, archive,
   and `SHA256SUMS`. Verify the uploaded archive matches the checksum and
   that the release points to the tested commit.

When SQLite publishes a security fix, assess whether the bundled version is
affected. If it is, update `sqlite3_abi`, run the release checks, and publish
a patch release with the SQLite version named in its notes.
