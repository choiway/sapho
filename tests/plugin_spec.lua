describe('sapho reading commands', function()
  it('registers entry, navigation and cancellation without edit commands', function()
    vim.cmd('runtime plugin/sapho.lua')
    for _, command in ipairs({ 'Sapho', 'SaphoToggle', 'SaphoLocations', 'SaphoNew', 'SaphoCancel', 'SaphoPause' }) do
      assert.are.equal(2, vim.fn.exists(':' .. command))
    end
    for _, command in ipairs({ 'SaphoAccept', 'SaphoReject', 'SaphoRevise', 'SaphoDiff' }) do
      assert.are.equal(0, vim.fn.exists(':' .. command))
    end
  end)
end)
