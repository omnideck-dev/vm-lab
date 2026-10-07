---
type: fixed
area: controller
---

Installing the controller from an exported source snapshot now records its
`SOURCE_COMMIT` base hash and marks the source as unverified dirty. Missing or
invalid markers report an unknown source instead of borrowing a commit from
an unrelated enclosing Git checkout.
