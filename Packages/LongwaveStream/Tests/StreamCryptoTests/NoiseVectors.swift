// Published Noise test vectors, copied verbatim (generated, do not edit):
//   cacophony  https://github.com/haskell-cryptography/cacophony  vectors/cacophony.txt
//   snow       https://github.com/mcginty/snow                    tests/vectors/snow.txt
// Every NN-family vector for 25519 / ChaChaPoly / SHA256, fetched 2026-10-24.
// Messages after the handshake are Noise transport messages under the split keys,
// alternating initiator and responder as the vector files define.

struct NoiseVector {
    struct Message {
        var payload: String
        var ciphertext: String
    }
    var source: String
    var protocolName: String
    var prologue: String
    var psks: [String]
    var initiatorEphemeral: String
    var responderEphemeral: String
    var handshakeHash: String?
    var messages: [Message]
}

let noiseVectors: [NoiseVector] = [
    NoiseVector(
        source: "cacophony",
        protocolName: "Noise_NN_25519_ChaChaPoly_SHA256",
        prologue: "4a6f686e2047616c74",
        psks: [],
        initiatorEphemeral: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        responderEphemeral: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        handshakeHash: "9223fec1b892ec9d0dc2fb3bbeb261f170d1ea679f9c44ccf34aa131b4f5d97e",
        messages: [
            .init(payload: "4c756477696720766f6e204d69736573",
                  ciphertext: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"),
            .init(payload: "4d757272617920526f746862617264",
                  ciphertext: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843a0ff96bdf86b579ef7dbf94e812a7470b903c20a85a87e3a1fe863264ae547"),
            .init(payload: "462e20412e20486179656b",
                  ciphertext: "eb1a3e3d80c1792b1bb9cb0e1382f8d8322bfb1ca7c4c8517bb686"),
            .init(payload: "4361726c204d656e676572",
                  ciphertext: "c781b198d2a974eb1da2c7d518c000cf6396de87ca540963c03713"),
            .init(payload: "4a65616e2d426170746973746520536179",
                  ciphertext: "c77048eb6919fdfe8fe45842bfc5b8d1ff50d1e20c717453ccdfe6176d805b996d"),
            .init(payload: "457567656e2042f6686d20766f6e2042617765726b",
                  ciphertext: "61834d7069dcfb7a1adf8d5ac910f83fa04c73a67789895c6f5f995c5db2ce88e49b124178"),
        ]
    ),
    NoiseVector(
        source: "cacophony",
        protocolName: "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        prologue: "4a6f686e2047616c74",
        psks: ["54686973206973206d7920417573747269616e20706572737065637469766521"],
        initiatorEphemeral: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        responderEphemeral: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        handshakeHash: "f4d03dc34495c95729ea6de9e1b59004b59733102488b3e24bc441e0be208eaf",
        messages: [
            .init(payload: "4c756477696720766f6e204d69736573",
                  ciphertext: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c794479b962b8aff8485742ac32f905ba45369e2465fb59e138a93d67a0d1266b6a54"),
            .init(payload: "4d757272617920526f746862617264",
                  ciphertext: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843d6062704d5a9c422a8e834423f8c1feada7e8d0d910a1a2cd030fb584221e3"),
            .init(payload: "462e20412e20486179656b",
                  ciphertext: "e632c3763d7669067383433197a3baddf146e9e70ad4b4e9e59e0f"),
            .init(payload: "4361726c204d656e676572",
                  ciphertext: "64c6bee32ea91c8474bb4c21d7a700109ad45af77b29764ba5eb1e"),
            .init(payload: "4a65616e2d426170746973746520536179",
                  ciphertext: "e2fa0bed0603b62d3ccac2ecabbf3fe33f3e86514909b323361626266cb2471cc8"),
            .init(payload: "457567656e2042f6686d20766f6e2042617765726b",
                  ciphertext: "0c01dc9cec1fe4ddd692e8dd32188aa351088dc91183639a53b57aa4692b5ebdef8b8ca111"),
        ]
    ),
    NoiseVector(
        source: "cacophony",
        protocolName: "Noise_NNpsk2_25519_ChaChaPoly_SHA256",
        prologue: "4a6f686e2047616c74",
        psks: ["54686973206973206d7920417573747269616e20706572737065637469766521"],
        initiatorEphemeral: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
        responderEphemeral: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        handshakeHash: "bb9704f2303bd8b98b40fdb2ee50c2a9a46d7d20ea4d0949ae3094e376b29b1c",
        messages: [
            .init(payload: "4c756477696720766f6e204d69736573",
                  ciphertext: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944d44698de33ea6b7eea8023b48a284404489f9976c5f03417e8e2d6db7ab6bb9f"),
            .init(payload: "4d757272617920526f746862617264",
                  ciphertext: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884361200acbacd001a0d19a826982488f52573687652551ca5e903db095fedc7a"),
            .init(payload: "462e20412e20486179656b",
                  ciphertext: "5ac8678baf0ef0cf884ab3271236b7ee57a02519505f4a4be09b95"),
            .init(payload: "4361726c204d656e676572",
                  ciphertext: "fe899e844ac0d348a3ab679b83c95fd1099f734a0dc085955adce2"),
            .init(payload: "4a65616e2d426170746973746520536179",
                  ciphertext: "f8800be62325c8bd6794f7e533bb90316c6ba569a4223e644175f4e5e458e840fd"),
            .init(payload: "457567656e2042f6686d20766f6e2042617765726b",
                  ciphertext: "2f60885aedcd5b5c142a3190208b540407ab4477528ea8d15bd795416575e58121098a4a9f"),
        ]
    ),
    NoiseVector(
        source: "snow",
        protocolName: "Noise_NN_25519_ChaChaPoly_SHA256",
        prologue: "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
        psks: [],
        initiatorEphemeral: "ba743ce40b65ad7ec0700dc2e57de4791022a8f42cd46517c6689c5c812b3b36",
        responderEphemeral: "d5cb9c3d9df2b6263f292f59099680ab2b523cf02b43a4c534b1fa94f9a80ed8",
        handshakeHash: nil,
        messages: [
            .init(payload: "d369dc8436b80ad2936b4179ef262a0d174c06e3d452de5f22a7ca0326baaac7",
                  ciphertext: "479a148ee78e18278f7716338574086a12bf8d90cc54c6c88ae6a4275dbd1478d369dc8436b80ad2936b4179ef262a0d174c06e3d452de5f22a7ca0326baaac7"),
            .init(payload: "87f4ce9acdcfe73e88f0d2b7e8b6009f07c5a42b3412909c1b7ce407a763ebd1",
                  ciphertext: "5f1bc611a449717c2fc7c33a0f3976beae914c336d2a761c2f6e1ee2ab721f7c166608582f25b34bf5ebe478049971b64e5982d8b546b1cfa58fae828b7c8137562fdec5808f41fadeeee43013019277"),
            .init(payload: "bdc326451b8af9b6b82a2054643878d9eeaea4845c6b1e9ba616b2723c2ef272",
                  ciphertext: "15f337bd32ddb96a17765a9499a4eb24b757d59c78d5366fdd56a2eab7eed11a0b6d4ed2947c0bf83d9d625ab90ee60b"),
            .init(payload: "a783aa12cefa403d1dff9d6ac924f860a15d1ba21c2c4976f8fa88d76e590fef",
                  ciphertext: "6b676682c308c230a602d1997ff9e94b815dbc497346a4144fc4290021a2dbfcbee618798a8eb5042562a637927d4e98"),
        ]
    ),
    NoiseVector(
        source: "snow",
        protocolName: "Noise_NNpsk0+psk2_25519_ChaChaPoly_SHA256",
        prologue: "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
        psks: ["198fd1f065a2189e08601b528466c8cf8aec05a4816a8a61fec565d8c12ecf04", "a1a156e77447faccbe3822d80cd53d3941299f7f717c4c7e6fbc06927ee17224"],
        initiatorEphemeral: "24ad913c4fdeae0cdd7a44f70d0dc625b22f29e15ed8dca775d981012a3491ff",
        responderEphemeral: "c53a56ddfd32229f424a732a427f22ad1bf37e6878db43a12283f60a101a79fa",
        handshakeHash: nil,
        messages: [
            .init(payload: "abb6b87769fa6f5731060e734f0fc34f032cc7db99265abdcfd660493a4a53d4",
                  ciphertext: "f6dd88576fa3bb6f3c3522e8f7539747529609442bd22e1ce06c6ad05cb56d3e3e5965d4d3ee60223c34873cae9e8c4b3462a780911c3d0567608419a9ecc7f433ed9f4f3b222fe954d6dd2abac6e30c"),
            .init(payload: "3b91c761cea263d20482ffc06639b7a87f87c0bb0926b9c6d47d45a10c8de9eb",
                  ciphertext: "83b28e814d65fb36070122d93621372b1216e8e628b001b6022c0bd4e8d88f0cbb8ef0a31f97d5eb579d067b717a2e75df1aae73e87d6e7c3f7721ba7fc3fc2e47a7ad6770db3cc83997ef9a9e8dddc7"),
            .init(payload: "eb8fc205a11e2108150c2f4837fad0102ee4a586168a64f21f77c016c18a39d4",
                  ciphertext: "28d536188b139d907b7320893550964d2464617e36ff4061d95e7a16eaee93d22845c4e8e4530a86d828a9d40198db24"),
            .init(payload: "6465c036eff856efdde1e63cddc4657322fb2fdc50e41b5d8f16c5f80db36933",
                  ciphertext: "179a6f5ba91b457f8eb302c0c089d37d3d446aa7f1eb00b8f3bb178df4d652466d0ebec66909ba9f5d5bf19111525538"),
        ]
    ),
]
