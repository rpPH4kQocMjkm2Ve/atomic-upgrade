v: 0.1

A common fact that internet is dead. Only search crawlers (bots) and a plenty of inactive users is here (maybe).

Well this document is not about that.

Here i will explain why this project is even needed, why it came to be, and what i didn't like about other solutions.

This doc was written because i don't like publishing anywhere (and there's no point if the internet is dead), and also i like keeping this kind of documentation in the code repository.

---

Let's start with an introduction. Some background, i mean.

One day i needed to set up a new device, onto which I, as a matter of fact, rolled up LUKS.
GRUB, as always, broke my cmdline, i couldn't boot, and in the end i simply removed it.

At first i tried using raw EFI entries. Overall, the result was ok.
Later, i discovered UKI, i think on the Arch Wiki.

I rolled with it. Along the way i was migrating to chezmoi (dotm didn't exist back then).

At some point, the idea came to me to combine UKI and btrfs subvolumes into a single entity.
That's how atomic-upgrade came to be.

Initially, an approach with hash sums in generation names was planned, but that idea was quickly discarded in favor of dates, because the hash-sum approach gave nothing (except headaches and poor readability).

Almost all iteration took place in chat with an LLM, because i have no one else to discuss technical ideas with.

The project itself grew inside a dotfiles repository, and later i moved it to a separate repository (about a month later, i think), when i found it more convenient to develop in a dedicated repo.
After that, it grew tests and documentation.

Basically, nearly all the code is discussed with an LLM (sometimes different ones) in several iterations, and new features are tested manually after being covered with tests by the LLM.

So, at the end of the day, we have an entity consisting of:
UKI
a btrfs subvolume

This entity is managed by the main orchestrator and subprograms.

The entity manages the root layer. i don't use the "@" naming convention, because i find it misleading and hard for people to understand.
The home subvolume layer, or other subvolumes, are not managed by the "atomic-upgrade" entity (except for tagged subvolumes with a special flag for experiments, but that functionality appeared later).


This document will be expanded (maybe).

---

I know there are some grammar errors, will not fix cuz not a tech doc.

---

Explanation of the document's name:
(post) - in parentheses, because the project is still alive
MORTEM.md - signifies the project's liveliness

When the project dies (and it will, nothing lasts forever), this will turn into a real post-mortem.
