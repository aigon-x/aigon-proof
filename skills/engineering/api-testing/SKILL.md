---
name: api-testing
description: >
  Umbrella skill for testing RESTful APIs and diagnosing HTTP status responses.
category: testing
---


# API Testing Skill

This umbrella skill provides reusable patterns and best practices for testing RESTful APIs.  Its
focus is on:
- Endpoint discovery and verification
- HTTP method support and status‑code expectations
- Automated status‑code checks (200, 400‑500 ranges)
- Handling of unexpected responses (e.g., 405 Method Not Allowed)
- Integration with CI workflows for regression tests

**Reference documents**:
- See `references/405-rejection.md` for a concrete example of diagnosing a 405 response.
- See `references/stripe-setup.md` for Stripe integration diagnostics.
