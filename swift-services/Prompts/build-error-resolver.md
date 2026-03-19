# Build Error Resolution

The quality gate detected build or type errors. Fix them without changing business logic.

## Build Output
```
{{BUILD_OUTPUT}}
```

## Type Check Output
```
{{TYPECHECK_OUTPUT}}
```

## Instructions
1. Read each error carefully
2. Fix the root cause (not symptoms)
3. Do NOT add type casts or `any` types to suppress errors
4. Do NOT change business logic — only fix build/type issues
5. Run build and typecheck again to verify fixes
6. Commit fixes with message: "fix: resolve build errors"
