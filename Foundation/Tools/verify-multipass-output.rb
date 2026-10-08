#!/usr/bin/env ruby
# Independent read-only verifier. Supply output folder, then original DV paths
# in the exact BASE, DONOR 1, ... order. Never follows paths from the report.
require 'json'
require 'digest'
abort 'Usage: verify-multipass-output.rb output-directory base.dv donor1.dv [...]' if ARGV.length < 3
root, *paths = ARGV
receipt = JSON.parse(File.read(File.join(root, 'merge.json')))
raise 'not a completed media derivative' unless receipt.fetch('state') == 'verified_reviewed_derivative'
{'review.json' => 'reviewSHA256', 'merged.dv' => 'mediaSHA256', 'provenance.ndjson' => 'provenanceSHA256'}.each do |file, key|
  raise "artifact hash: #{file}" unless Digest::SHA256.file(File.join(root, file)).hexdigest == receipt.fetch(key)
end
raise 'input count' unless paths.length == receipt.fetch('inputs').length
sources = paths.each_with_index.map do |path, i|
  raise "source hash: pass #{i}" unless Digest::SHA256.file(path).hexdigest == receipt.fetch('inputs')[i].fetch('source').fetch('source_sha256')
  File.open(path, 'rb')
end
review = JSON.parse(File.read(File.join(root, 'review.json')))
candidates = review.fetch('candidates').to_h { |c| ["#{c.fetch('baseFrame')}:#{c.fetch('donorPass')}:#{c.fetch('donorFrame')}", c] }
choices = review.fetch('reviews').to_h { |r| [r.fetch('baseFrame'), r.fetch('choice')] }
media = File.open(File.join(root, 'merged.dv'), 'rb')
count = 0
File.foreach(File.join(root, 'provenance.ndjson')) do |line|
  p = JSON.parse(line)
  n = p.fetch('byteCount'); pass = p.fetch('sourcePass'); source_frame = p.fetch('sourceFrame')
  raise 'invalid size/pass' unless [120000, 144000].include?(n) && pass.between?(0, sources.length - 1)
  expected = choices[count]
  chosen = expected && expected != 'original' ? candidates.fetch(expected) : nil
  raise 'review/provenance mismatch' unless pass == (chosen ? chosen.fetch('donorPass') : 0) &&
    source_frame == (chosen ? chosen.fetch('donorFrame') : count) && p.fetch('choice') == (chosen ? expected : 'original')
  raise 'offset or ordinal' unless p.fetch('outputFrame') == count && p.fetch('outputByteOffset') == count * n && p.fetch('sourceByteOffset') == source_frame * n
  bytes = media.read(n)
  original = sources[pass].pread(n, p.fetch('sourceByteOffset'))
  raise "selected bytes: frame #{count}" unless bytes&.bytesize == n && bytes == original && Digest::SHA256.hexdigest(bytes) == p.fetch('frameSHA256')
  raise 'provenance source hash' unless p.fetch('sourceSHA256') == receipt.fetch('inputs')[pass].fetch('source').fetch('source_sha256')
  count += 1
end
raise 'frame count or unexpected tail' unless count == receipt.fetch('frames') && media.read(1).nil?
media.close; sources.each(&:close)
puts "INDEPENDENT_MULTIPASS_VERIFICATION_PASS: #{count} frames; all input/artifact hashes, reviewed selections, original bytes and per-frame provenance match"
