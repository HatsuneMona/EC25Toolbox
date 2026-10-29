# Third-party notices

## SmsForwarder

The SMS forwarding feature ports Feishu custom-bot signing/card behavior,
Webhook signing, and common template-variable behavior from
[pppscn/SmsForwarder](https://github.com/pppscn/SmsForwarder), commit
`ce931a03739a6a2b0dfc83161bf812a94fd5e45e`.

Reference files: `app/src/main/kotlin/cn/ppps/forwarder/utils/sender/FeishuUtils.kt`
and `WebhookUtils.kt`. The persistent queue, native SwiftUI integration,
Keychain storage, and modem archive adapter are implemented in Swift.

The complete BSD 2-Clause notice below is also distributed in the app resource
`ThirdParty/SmsForwarder-LICENSE.txt`.

BSD 2-Clause License

Copyright (c) 2021, pppscn
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
