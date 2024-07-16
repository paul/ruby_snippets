# frozen_string_literal: true

# Author:  Paul Sadauskas<paul@sadauskas.com>
# License: MIT

# Capybara helper to find a link/button/submit via the rel attribute
#
# More info: https://steveklabnik.com/writing/write-better-cukes-with-the-rel-attribute
#
# ex: find(:app, 'edit-article').click
# will find: <a href='' rel='app:edit-article'>...</a>
#
Capybara.add_selector(:app) do
  xpath { |rel|
    ".//a[contains(./@rel,'app:#{rel}')] | .//button[contains(./@rel,'app:#{rel}')] | .//input[./@type='submit'][contains(./@rel,'app:#{rel}')]"
  }
end

