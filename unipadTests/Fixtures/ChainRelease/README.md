# Approved chain-release fixtures

Byte-for-byte copies from UniPad web commit `388bff2b20bdb997bd0892f2bdb6968c89dfeee9`
(original reviewed head `f9a23cd068caa639bd300b2273f89d22d5791412`),
`meta/unipack-conformance/chain-release-v1/`, delivered by JIS-339.
Source attachment: `/api/attachments/a547ade1-0311-4f53-8129-a107d9b32634/content`.
The source manifest preserves the hashes of the archives, expectations, and their contents.
`ChainReleaseTests.testApprovedFixtureBytesMatchSourceRevision` checks the copied archive
and expectations hashes against both pinned values and the unchanged manifest.

The six cases use the production parser, screen model, and audio engine. Input steps
are performed synchronously; asynchronous checkpoints wait for the real pack chain move
or finite voice completion with a 120-second silence limit. Nominal `atMs` labels describe
corpus order, not a measurement of exact wall-clock timing on a simulator. Audio player
IDs and pressed lights are observations, not listening or real simultaneous fingers.
The original 124-case corpus, KS-003, archived 60 rows, and pass rates are unchanged.
