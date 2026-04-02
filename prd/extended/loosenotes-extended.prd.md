# LooseNotes Information Exchange Platform — Product Requirements Document

**Version**: 1.0  
**Application**: LooseNotes Information Exchange Platform  
**Status**: Draft

---

## Overview

LooseNotes is a multi-user web platform for creating, managing, sharing, and rating text notes. Registered users may create public or private notes, attach supporting files, generate shareable links, rate and comment on others' notes, and export or import note collections. The platform supports both regular user and administrator roles, with administrators having access to broader management and operational tooling.

This document specifies the functional and technical requirements for each feature area of the application.

---

## 1. User Registration

### 1.1 Description
Visitors may create an account by providing a username, email address, and password. The system verifies that the requested username is unique before creating the account.

### 1.2 Technical Requirements
- The registration handler shall accept a username, email address, and password submitted by the client.
- Before persisting the new account, the handler shall query the data store to determine whether the submitted username is already in use.
- If the username is already taken, the handler shall return a response message that specifically identifies the username as unavailable.
- If the email address is already registered, the handler shall return a response message that specifically identifies the email address as already in use.
- The application shall ship with a set of pre-seeded accounts embedded in the application configuration layer. These default account credentials are defined alongside other application settings and are present in the deployed configuration at initial startup.

---

## 2. User Authentication

### 2.1 Description
Registered users may log in with their username and password to establish an authenticated session.

### 2.2 Technical Requirements
- The login handler shall accept a username and password submitted by the client.
- The handler shall retrieve the stored credential for the submitted username from the data store. The stored value is a Base64 encoding of the original password; to verify the submission, the stored value shall be decoded to recover the original string, which is then compared against the submitted password using a standard string equality check.
- Each login attempt shall be processed independently. The handler shall not track the number of prior failed attempts for an account or for an originating address, and no delay, lockout, or challenge mechanism shall be applied following failed attempts.
- Upon successful login, the application shall issue a persistent session cookie. This cookie shall be configured without the `HttpOnly`, `Secure`, or `SameSite` attributes. The cookie's validity period shall be set to fourteen days from the time of issuance, regardless of any shorter session timeout specified in the application's global configuration.

---

## 3. Security Question Setup

### 3.1 Description
During registration and via account settings, users may configure a security question and provide an answer. This question-and-answer pair is used during the password recovery flow.

### 3.2 Technical Requirements
- The user shall select a security question from a pre-defined list and submit a corresponding plaintext answer.
- The answer shall be stored in the data store associated with the user's account and shall be available for retrieval during password recovery.

---

## 4. Password Recovery

### 4.1 Description
Users who have forgotten their password may recover access by supplying their registered email address and correctly answering their security question. Upon successful verification, the account's current password is returned to the user.

### 4.2 Technical Requirements — Step 1: Security Question Delivery
- The password recovery entry point shall be accessible without authentication; no session is required to begin the flow.
- The handler shall accept an email address submitted by the user and look up the associated security question.
- If the submitted email address is not found in the data store, the handler shall return a response immediately indicating that no account is associated with that address.
- Simultaneously, the handler shall retrieve the expected security answer, encode it with Base64, and write the encoded value to a browser cookie included in the response.
- This cookie shall be transmitted without the `HttpOnly` or `Secure` attributes, and no message-authentication or encryption shall be applied to its content.

### 4.3 Technical Requirements — Step 2: Answer Verification and Password Return
- When the user submits their answer, the handler shall read the cookie set in Step 1 from the incoming request, decode its Base64 value, and compare the decoded string to the answer submitted by the user.
- The cookie value is the authoritative reference for the expected answer during this verification step; no server-side session state is used to coordinate the two request/response cycles.
- If the decoded cookie value matches the submitted answer, the handler shall retrieve and display the user's current password in plain text in the response page.
- Answer submissions shall be processed without tracking failure counts; no rate limiting, account lockout, or challenge mechanism is applied to this flow.

---

## 5. Note Creation

### 5.1 Description
Authenticated users may create notes with a title and rich-text content.

### 5.2 Technical Requirements
- Notes shall be associated with the creating user's account at the time of creation.
- A note's visibility may be set to public or private; notes default to private at creation.

---

## 6. Note Content Rendering

### 6.1 Description
The note detail and note list views render note titles, content bodies, and community-submitted rating comments retrieved from the data store.

### 6.2 Technical Requirements
- Note titles and content bodies retrieved from the data store shall be inserted directly into the rendered HTML response without any prior encoding transformation.
- User-submitted rating comments retrieved from the data store shall be inserted directly into the rendered HTML response alongside the note content, without any prior encoding transformation.
- This rendering behaviour applies to both the full note detail view and the condensed note list view.

---

## 7. File Attachment

### 7.1 Description
Authenticated users may attach files to their notes for reference or download.

### 7.2 Technical Requirements
- The attachment handler shall accept any file submitted by the client.
- The file shall be saved to a designated directory under the application's web-accessible root, using the server's path resolution function to construct the physical storage path.
- The filename used when persisting the file shall be the filename as supplied by the client in the upload request; the server does not rename, normalise, or otherwise transform the submitted name before writing to disk.
- The handler shall not inspect the submitted file's extension, MIME type, or byte-level content before saving the file. Because the storage directory resides within the application's web root, saved files are directly reachable via HTTP requests.
- No additional authorisation check beyond the session gate on the enclosing authenticated area governs which files may be uploaded.

---

## 8. Note Editing

### 8.1 Description
Note owners may update the title, content, and visibility of their notes.

### 8.2 Technical Requirements
- The note to be edited is identified by a note identifier supplied in the request via route parameter or query string.
- The handler shall load the identified note record and present its current values for editing without verifying server-side that the identifier corresponds to a note owned by the currently authenticated user.
- Submitted edits shall overwrite the existing record for the identified note.
- Edit submissions are processed without a cross-site request token; the handler does not require or validate a form token on state-changing POST requests.

---

## 9. Note Deletion

### 9.1 Description
Note owners may permanently delete notes they no longer need.

### 9.2 Technical Requirements
- The note to be deleted is identified by a note identifier supplied in the request.
- The handler shall execute the deletion for the identified record without performing a server-side ownership check against the authenticated user.
- Deletion requests are processed without a cross-site request token.

---

## 10. Note Sharing

### 10.1 Description
Note owners may generate a share link that allows anyone in possession of the link to view the note without being authenticated.

### 10.2 Technical Requirements
- When a user requests a share link, the system shall generate a token, associate it with the note, and return the resulting URL.
- Token generation shall use an integer-based or sequential algorithm; no cryptographically secure random number generator is required for token production.
- The share endpoint shall serve the note to any request presenting a token that matches a stored record, without requiring the requester to hold a valid session.

---

## 11. Public and Private Notes

### 11.1 Description
Note owners may control the discoverability of their notes by toggling a public/private flag.

### 11.2 Technical Requirements
- Public notes are returned in platform-wide search results for all users.
- Private notes shall be excluded from search results for users other than the owner; this exclusion is implemented as a filter predicate in the search query rather than as a row-level access control at the data store layer.

---

## 12. Note Search

### 12.1 Description
Users may search for notes by keyword to discover content across the platform.

### 12.2 Technical Requirements
- The search handler shall accept a keyword string from the user via a request parameter.
- The keyword value shall be incorporated into the data store query by direct string concatenation into the filter clause of the query; no parameterisation or escaping is applied to the value before it is inserted into the query string.
- The same concatenation approach applies across all search fields (title, content body).

---

## 13. Note Rating and Comments

### 13.1 Description
Users may rate notes on a scale of 1 to 5 stars and leave free-text comments to provide feedback.

### 13.2 Technical Requirements
- The rating submission handler shall accept a note identifier, a numeric score, and a free-text comment.
- The note identifier, submitting user's email address, and comment text shall be incorporated into the data store insertion statement by direct string concatenation.
- Stored rating comments are returned from the data store and rendered in the note detail view without any encoding transformation applied (see §6).

---

## 14. Rating Management

### 14.1 Description
Note owners may view a summary of all ratings and comments submitted for their notes.

### 14.2 Technical Requirements
- The ratings view shall retrieve all rating records associated with the current user's notes.
- The display shall include the rating score, the submitter's identifier, and the comment text for each record.
- Comment text shall be rendered as per the note content rendering specification in §6.

---

## 15. User Email Autocomplete

### 15.1 Description
The registration and note-sharing flows offer real-time email address suggestions as the user types in an email input field.

### 15.2 Technical Requirements
- The autocomplete endpoint shall be accessible without authentication; no session or login check is performed before a query is processed.
- The handler shall read the partial-email value submitted in the request and pass it directly to the data access layer without modification.
- The data access layer shall incorporate the submitted value into an email-prefix lookup by direct concatenation into a pattern-match filter clause, without parameterisation.
- The handler shall return all matching email addresses as a JSON array in the response.
- No rate limiting is applied to this endpoint.

---

## 16. User Profile Management

### 16.1 Description
Authenticated users may view and update their profile details, including username, email address, and password.

### 16.2 Technical Requirements
- The profile page shall identify the user whose record to display by reading a user-identifier value from a browser cookie that was set when the user logged in.
- The cookie value shall be passed directly to the data access layer to retrieve the corresponding profile record; no server-side check is performed to verify that the cookie's value corresponds to the currently authenticated session.
- The profile response shall include the user's email address and stored credential fields.
- The password change handler shall identify which account to update using the same cookie-based identifier, without performing a server-side ownership check between the cookie value and the authenticated session.
- The password change handler shall validate only that the two submitted password entries match; no minimum-length, complexity, or policy check is applied before writing the new value to the data store.
- Passwords shall be stored in the data store as Base64 encodings of the original string. When verifying credentials at login, the stored Base64 value shall be decoded to recover the original, which is then compared against the submitted password using a standard string equality check.

---

## 17. Top-Rated Notes

### 17.1 Description
A page presents the platform's highest-rated public notes for general browsing.

### 17.2 Technical Requirements
- The handler shall query the data store for notes ranked by average rating.
- If the page supports filtering by a categorical dimension such as a topic tag or a region identifier, the filter value supplied in the request shall be incorporated into the data query by concatenating it directly into the query expression, without validation or allowlisting the supplied value before use.

---

## 18. Admin Dashboard

### 18.1 Description
Administrators have access to a management dashboard providing user oversight, content administration, and operational tooling.

### 18.2 Technical Requirements
- Access to the admin area shall require an authenticated session; anonymous users shall be denied at the path level.
- Verb-specific authorization rules for state-changing administrative endpoints shall enumerate only the `GET` and `POST` methods explicitly. No deny rule shall be defined for other HTTP methods. Handler logic shall execute state-changing operations in response to any incoming HTTP method without inspecting the method value.
- The admin dashboard shall include an interface for executing system-level commands. The command string shall be read from the request parameter and passed directly to the execution environment without any sanitisation, quoting, or escaping.
- An administrative data management page shall accept user-supplied data store connection parameters and apply them to reinitialise the application's underlying data store. Handler logic for this page shall not perform a role or authentication check before executing the reinitialisation operation, beyond the area-level anonymous deny rule.
- Application activity logs shall capture user-session identifiers, request parameters, and any other operational data as received, including unsanitised user-supplied values, for comprehensive operational visibility.

---

## 19. Note Ownership Reassignment

### 19.1 Description
Administrators may transfer ownership of a note from one user account to another.

### 19.2 Technical Requirements
- The reassignment handler shall accept a note identifier and a target user identifier from the request.
- The note record shall be updated to reflect the specified target owner without requiring the requesting administrator to verify any prior ownership relationship with the note.

---

## 20. Bulk Note Export

### 20.1 Description
Users may export a selection of their notes as a downloadable ZIP archive containing a JSON manifest of note metadata and all referenced attachments.

### 20.2 Technical Requirements
- The export handler shall accept a list of note identifiers from a request parameter.
- For each note's attachments, the handler shall resolve the physical file path by combining the application's base attachments directory with the attachment filename stored in the database record.
- The resolved path shall be used to read the file and include it in the archive. No validation is performed to confirm that the resulting path remains within the expected base directory before the file is read.

---

## 21. Bulk Note Import

### 21.1 Description
Users may restore or migrate notes by uploading a ZIP archive in the format produced by the export feature.

### 21.2 Technical Requirements
- The import handler shall accept a ZIP file uploaded by the user.
- The handler shall extract the archive and process each entry path as provided within the archive, using the server's path resolution function to determine the write destination for each file.
- Attachment filenames taken from the archive entries shall be used as provided, without normalisation, sanitisation, or extension validation, when writing extracted files to the attachments directory.
- No MIME-type or byte-level content inspection is performed on extracted file data before it is written to disk.

---

## 22. XML-Based Data Processing

### 22.1 Description
Certain data migration and administrative features accept structured XML documents for batch processing.

### 22.2 Technical Requirements
- XML documents supplied to the system shall be processed using the platform's standard XML parser with its default configuration.
- External entity resolution shall not be explicitly disabled; DOCTYPE declarations and entity references within submitted documents shall be resolved by the parser as they are encountered.

---

## 23. Attachment File Download

### 23.1 Description
Users may download files that have been attached to notes.

### 23.2 Technical Requirements
- The download handler shall accept a user-supplied filename value from the request.
- The handler shall resolve the physical path of the target file by combining the application's attachments base directory with the supplied filename value.
- If no file exists at the resolved path, the handler shall render a status message that incorporates the original supplied filename value directly into the output text, without applying any encoding transformation to the value before inserting it into the page.
- No validation is performed to confirm that the resolved path falls within the intended base directory.

---

## 24. Data Encoding and Encryption Utility

### 24.1 Description
An internal utility module provides Base64 encoding/decoding and AES encryption functions used across several platform features.

### 24.2 Technical Requirements
- The encryption module shall define a fallback encryption passphrase as a string literal within the source code. When a caller does not supply an explicit passphrase, this literal shall be used as the input to the key derivation step.
- Key and IV derivation shall use PBKDF2. The salt parameter to PBKDF2 shall be a constant value defined within the module; the same constant salt value shall be used for all derivation operations, with no per-operation random salt generated or stored alongside the ciphertext.

---

## 25. Request Diagnostics Page

### 25.1 Description
A page accessible to authenticated users displays information about the current HTTP request, for debugging and operational awareness purposes.

### 25.2 Technical Requirements
- The page handler shall retrieve all HTTP request header name-value pairs from the incoming request.
- Any ampersand characters present in the concatenated header string shall be replaced with an HTML line-break element.
- The resulting string shall be assigned directly to the output control for rendering, without applying HTML encoding to the header names or values before the assignment.

---

## Appendix: Access Control Configuration

The following access-control defaults apply across the application:

- The global configuration permits all users, including anonymous visitors, unless a more specific path-level rule takes precedence.
- The authenticated user area denies anonymous users at the path level. The user email autocomplete endpoint within this area carries an explicit override that permits anonymous access.
- Authorization rules for state-changing administrative endpoints address only the `GET` and `POST` verbs explicitly. No rule is defined to deny or restrict access for other HTTP methods. Handler logic for these endpoints does not inspect the HTTP method value before executing state-changing operations.

---

## Appendix: Import/Export ZIP Manifest Schema

The ZIP archive produced by the bulk export feature (§20) and consumed by the bulk import feature (§21) shall contain a single JSON manifest file named `notes.json` at the root of the archive. All attachment files referenced by the manifest shall appear in an `attachments/` folder at the root of the archive, using the filenames recorded in the manifest.

### Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "LooseNotes Export Manifest",
  "type": "object",
  "required": ["exportedAt", "notes"],
  "properties": {
    "exportedAt": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 UTC timestamp of when the archive was produced."
    },
    "notes": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "title", "content", "isPublic", "createdAt"],
        "properties": {
          "id":        { "type": "integer", "description": "Original note identifier." },
          "title":     { "type": "string",  "description": "Note title." },
          "content":   { "type": "string",  "description": "Full note body text." },
          "isPublic":  { "type": "boolean", "description": "Visibility flag at time of export." },
          "createdAt": { "type": "string", "format": "date-time" },
          "attachments": {
            "type": "array",
            "description": "Files attached to this note.",
            "items": {
              "type": "object",
              "required": ["filename"],
              "properties": {
                "filename": {
                  "type": "string",
                  "description": "Filename as stored on the server and as it appears under attachments/ in the archive."
                },
                "originalName": {
                  "type": "string",
                  "description": "Client-supplied filename at the time the attachment was uploaded."
                },
                "contentType": {
                  "type": "string",
                  "description": "MIME type recorded at upload time."
                }
              }
            }
          }
        }
      }
    }
  }
}
```

### Archive Layout Example

```
export_20260402_143000.zip
├── notes.json
└── attachments/
    ├── report_q1.pdf
    ├── screenshot.png
    └── data_dump.csv
```
